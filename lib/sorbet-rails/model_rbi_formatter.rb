# typed: strict
require('parlour')
require('sorbet-rails/model_utils')
require('sorbet-rails/model_plugins/active_record_enum')
require('sorbet-rails/model_plugins/active_record_querying')
require('sorbet-rails/model_plugins/active_record_named_scope')
require('sorbet-rails/model_plugins/active_record_attribute')
require('sorbet-rails/model_plugins/active_record_assoc')
class ModelRbiFormatter
  extend T::Sig
  include SorbetRails::ModelUtils

  sig { implementation.returns(T.class_of(ActiveRecord::Base)) }
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
    rescue StandardError
      puts "Note: Unable to create new instance of #{model_class.name}"
    end
  end

  sig {returns(String)}
  def generate_rbi
    puts "-- Generate sigs for #{@model_class.name} --"

    # TODO: make this customizable
    plugins = [
      SorbetRails::ModelPlugins::ActiveRecordEnum,
      SorbetRails::ModelPlugins::ActiveRecordNamedScope,
      SorbetRails::ModelPlugins::ActiveRecordQuerying,
      SorbetRails::ModelPlugins::ActiveRecordAttribute,
      SorbetRails::ModelPlugins::ActiveRecordAssoc,
    ]

    # Collect the instances of each plugin into an array
    plugin_instances = plugins.map do |plugin_klass|
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

    <<~MESSAGE
      # This is an autogenerated file for dynamic methods in #{self.model_class_name}
      # Please rerun rake rails_rbi:models[#{self.model_class_name}] to regenerate.

      #{generator.rbi}
    MESSAGE
  end

  sig { params(root: Parlour::RbiGenerator::Namespace).void }
  def generate_base_rbi(root)
    # This is the backbone of the model_rbi_formatter.
    # It could live in a base plugin but I consider it not replacable and better to leave here
    model_relation_rbi = root.create_class(
      self.model_relation_class_name,
      superclass: "ActiveRecord::Relation",
    )
    model_relation_rbi.create_include(self.model_relation_shared_module_name)
    model_relation_rbi.create_extend("T::Sig")
    model_relation_rbi.create_extend("T::Generic")
    model_relation_rbi.create_constant(
      "Elem",
      value: "type_member(fixed: #{model_class_name})",
    )

    collection_proxy_rbi = root.create_class(
      self.model_assoc_proxy_class_name,
      superclass: "ActiveRecord::Associations::CollectionProxy",
    )
    collection_proxy_rbi.create_include(self.model_relation_shared_module_name)
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
    model_rbi.create_extend(self.model_relation_shared_module_name)
    model_rbi.create_constant(
      "Elem",
      value: "type_template(fixed: #{self.model_class_name})",
    )

    # <Model>::MODEL_RELATION_SHARED_MODULE_SUFFIX is a fake module added so that
    # when a method is defined in this module, it'll be added to both the Model class
    # as a class method and to its relation as an instance method.
    #
    # We need to define the module after the other classes
    # to work around Sorbet loading order bug
    # https://sorbet-ruby.slack.com/archives/CHN2L03NH/p1556065791047300
    model_relation_shared_rbi = root.create_module(self.model_relation_shared_module_name)
    model_relation_shared_rbi.create_extend("T::Sig")
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
        puts "!!! This plugin threw an exception: #{e}"
      end
    end
  end
end
