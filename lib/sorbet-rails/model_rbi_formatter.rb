# typed: strict
require('parlour')
require('sorbet-rails/model_utils')
require('sorbet-rails/model_plugins/plugins')

class SorbetRails::ModelRbiFormatter
  extend T::Sig
  extend SorbetRails::ModelPlugins
  include SorbetRails::ModelUtils

  sig { override.returns(T.class_of(ActiveRecord::Base)) }
  attr_reader :model_class

  sig { returns(T::Set[String]) }
  attr_reader :available_classes

  sig {
    params(
      model_class: T.class_of(ActiveRecord::Base),
      available_classes: T::Set[String],
    ).
    void
  }
  def initialize(model_class, available_classes)
    @model_class = T.let(model_class, T.class_of(ActiveRecord::Base))
    @available_classes = T.let(available_classes, T::Set[String])
    begin
      # Load all dynamic instance methods of this model by instantiating a fake model
      @model_class.new unless @model_class.abstract_class?
    rescue StandardError => err
      puts "#{err.class}: Note: Unable to create new instance of #{model_class.name}"
    end
  end

  sig {returns(String)}
  def generate_rbi
    puts "-- Generate sigs for #{@model_class.name} --"

    # Collect the instances of each plugin into an array
    plugin_instances = self.class.get_plugins.map do |plugin_klass|
      plugin_klass.new(model_class, available_classes)
    end

    generator = Parlour::RbiGenerator.new(break_params: 3)
    run_plugins(plugin_instances, generator, allow_failure: true)
    # Generate the base after the plugins because when ConflictResolver merge the modules,
    # it'll put the modules at the last position merged. Putting the base stuff
    # last will keep the order consistent and minimize changes when new plugins are added.
    generate_base_rbi(generator.root)

    Parlour::ConflictResolver.new.resolve_conflicts(generator.root) do |msg, candidates|
      puts "Conflict: #{msg}. Skip following methods"
      candidates.each do |c|
        puts "- Method `#{c.name}` generated by #{c.generated_by.class.name}"
      end
      nil
    end

    rbi = <<~MESSAGE
      # This is an autogenerated file for dynamic methods in #{self.model_class_name}
      # Please rerun rake rails_rbi:models[#{self.model_class_name}] to regenerate.

    MESSAGE

    rbi += generator.rbi
    return rbi
  end

  sig { params(root: Parlour::RbiGenerator::Namespace).void }
  def generate_base_rbi(root)
    # This is the backbone of the model_rbi_formatter.
    # It could live in a base plugin but I consider it not replacable and better to leave here
    model_relation_rbi = root.create_class(
      self.model_relation_class_name,
      superclass: "ActiveRecord::Relation",
    )
    model_relation_rbi.create_extend("T::Sig")
    model_relation_rbi.create_extend("T::Generic")
    model_relation_rbi.create_constant(
      "Elem",
      value: "type_member(fixed: #{model_class_name})",
    )

    model_assoc_relation_rbi = root.create_class(
      self.model_assoc_relation_class_name,
      superclass: "ActiveRecord::AssociationRelation",
    )
    model_assoc_relation_rbi.create_extend("T::Sig")
    model_assoc_relation_rbi.create_extend("T::Generic")
    model_assoc_relation_rbi.create_constant(
      "Elem",
      value: "type_member(fixed: #{model_class_name})",
    )

    collection_proxy_rbi = root.create_class(
      self.model_assoc_proxy_class_name,
      superclass: "ActiveRecord::Associations::CollectionProxy",
    )
    collection_proxy_rbi.create_extend("T::Sig")
    collection_proxy_rbi.create_extend("T::Generic")
    collection_proxy_rbi.create_constant(
      "Elem",
      value: "type_member(fixed: #{self.model_class_name})",
    )

    model_rbi = root.create_class(
      self.model_class_name,
      superclass: T.must(@model_class.superclass).name,
    )
    model_rbi.create_extend("T::Sig")
    model_rbi.create_extend("T::Generic")
  end

  sig {
    params(
      plugins: T::Array[Parlour::Plugin],
      generator: Parlour::RbiGenerator,
      allow_failure: T::Boolean,
    ).
    void
  }
  def run_plugins(plugins, generator, allow_failure: true)
    plugins.each do |plugin|
      begin
        generator.current_plugin = plugin
        plugin.generate(generator.root)
      rescue Exception => e
        raise e unless allow_failure
        puts "!!! Plugin #{plugin.class.name} threw an exception: #{e}"
      end
    end
  end
end
