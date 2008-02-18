module ActsAsFerret #:nodoc:

  # This module defines the acts_as_ferret method and is included into 
  # ActiveRecord::Base
  module ActMethods
          
    
    def reloadable?; false end
    
    # declares a class as ferret-searchable. 
    #
    # ====options:
    # fields:: names all fields to include in the index. If not given,
    #          all attributes of the class will be indexed. You may also give
    #          symbols pointing to instance methods of your model here, i.e. 
    #          to retrieve and index data from a related model. 
    #
    # additional_fields:: names fields to include in the index, in addition 
    #                     to those derived from the db scheme. use if you want 
    #                     to add custom fields derived from methods to the db 
    #                     fields (which will be picked by aaf). This option will 
    #                     be ignored when the fields option is given, in that 
    #                     case additional fields get specified there.
    #
    # index_dir:: declares the directory where to put the index for this class.
    #             The default is RAILS_ROOT/index/RAILS_ENV/CLASSNAME. 
    #             The index directory will be created if it doesn't exist.
    #
    # single_index:: set this to true to let this class use a Ferret
    #                index that is shared by all classes having :single_index set to true.
    #                :store_class_name is set to true implicitly, as well as index_dir, so 
    #                don't bother setting these when using this option. the shared index
    #                will be located in index/<RAILS_ENV>/shared .
    #
    # store_class_name:: to make search across multiple models (with either
    #                    single_index or the multi_search method) useful, set
    #                    this to true. the model class name will be stored in a keyword field 
    #                    named class_name
    #
    # reindex_batch_size:: reindexing is done in batches of this size, default is 1000
    # mysql_fast_batches:: set this to false to disable the faster mysql batching
    #                      algorithm if this model uses a non-integer primary key named
    #                      'id' on MySQL.
    #
    # raise_drb_errors:: Set this to true if you want aaf to raise Exceptions
    #                    in case the DRb server cannot be reached (in other word - behave like
    #                    versions up to 0.4.3). Defaults to false so DRb exceptions
    #                    are logged but not raised. Be sure to set up some
    #                    monitoring so you still detect when your DRb server died for
    #                    whatever reason.
    #
    # ferret:: Hash of Options that directly influence the way the Ferret engine works. You 
    #          can use most of the options the Ferret::I class accepts here, too. Among the 
    #          more useful are:
    #
    #     or_default:: whether query terms are required by
    #                  default (the default, false), or not (true)
    # 
    #     analyzer:: the analyzer to use for query parsing (default: nil,
    #                which means the ferret StandardAnalyzer gets used)
    #
    #     default_field:: use to set one or more fields that are searched for query terms
    #                     that don't have an explicit field list. This list should *not*
    #                     contain any untokenized fields. If it does, you're asking
    #                     for trouble (i.e. not getting results for queries having
    #                     stop words in them). Aaf by default initializes the default field 
    #                     list to contain all tokenized fields. If you use :single_index => true, 
    #                     you really should set this option specifying your default field
    #                     list (which should be equal in all your classes sharing the index).
    #                     Otherwise you might get incorrect search results and you won't get 
    #                     any lazy loading of stored field data.
    #
    # For downwards compatibility reasons you can also specify the Ferret options in the 
    # last Hash argument.
    def acts_as_ferret(options={})
      # default to DRb mode
      options[:remote] = true if options[:remote].nil?

      # force local mode if running *inside* the Ferret server - somewhere the
      # real indexing has to be done after all :-)
      # Usually the automatic detection of server mode works fine, however if you 
      # require your model classes in environment.rb they will get loaded before the 
      # DRb server is started, so this code is executed too early and detection won't 
      # work. In this case you'll get endless loops resulting in "stack level too deep" 
      # errors. 
      # To get around this, start the DRb server with the environment variable 
      # FERRET_USE_LOCAL_INDEX set to '1'.
      logger.debug "Asked for a remote server ? #{options[:remote].inspect}, ENV[\"FERRET_USE_LOCAL_INDEX\"] is #{ENV["FERRET_USE_LOCAL_INDEX"].inspect}, looks like we are#{ActsAsFerret::Remote::Server.running || ENV['FERRET_USE_LOCAL_INDEX'] ? '' : ' not'} the server"
      options.delete(:remote) if ENV["FERRET_USE_LOCAL_INDEX"] || ActsAsFerret::Remote::Server.running

      if options[:remote] && options[:remote] !~ /^druby/
        # read server location from config/ferret_server.yml
        options[:remote] = ActsAsFerret::Remote::Config.new.uri rescue nil
      end

      if options[:remote]
        logger.info "Will use remote index server which should be available at #{options[:remote]}"
      else
        logger.info "Will use local index."
      end

      extend ClassMethods

      include InstanceMethods
      include MoreLikeThis::InstanceMethods

      if options[:rdig]
        require 'rdig_adapter'
        include ActsAsFerret::RdigAdapter
      end

      unless included_modules.include?(ActsAsFerret::WithoutAR)
        # set up AR hooks
        after_create  :ferret_create
        after_update  :ferret_update
        after_destroy :ferret_destroy      
      end

      cattr_accessor :aaf_configuration

      # apply default config for rdig based models
      if options[:rdig]
        options[:fields] ||= { :title   => { :boost => 3, :store => :yes },
                               :content => { :store => :yes } }
      end

      # name of this index
      index_name = options.delete(:index) || self.name.underscore

      index = ActsAsFerret::register_class_with_index(self, index_name, options)
      self.aaf_configuration = index.index_definition
      logger.debug "configured index for class #{self.name}:\n#{aaf_configuration.inspect}"

      # update our copy of the global index config with options local to this class
      aaf_configuration[:class_name] ||= self.name

      # add methods for retrieving field values
      add_fields options[:fields]
      add_fields options[:additional_fields]
      add_fields aaf_configuration[:fields]
      add_fields aaf_configuration[:additional_fields]

      # not good at class level, index might get initialized too early
      #if options[:remote]
      #  aaf_index.ensure_index_exists
      #end
    end


    protected
    

    # helper to defines a method which adds the given field to a ferret 
    # document instance
    def define_to_field_method(field, options = {})
      method_name = "#{field}_to_ferret"
      return if instance_methods.include?(method_name) # already defined
      dynamic_boost = options[:boost] if options[:boost].is_a?(Symbol)
      via = options[:via] || field
      define_method(method_name.to_sym) do
        val = begin
          content_for_field_name(field, via, dynamic_boost)
        rescue
          logger.warn("Error retrieving value for field #{field}: #{$!}")
          ''
        end
        logger.debug("Adding field #{field} with value '#{val}' to index")
        val
      end
    end

    def add_fields(field_config)
      # TODO
        #field_config.each do |*args| 
        #  define_to_field_method *args
        #end                
      if field_config.is_a? Hash
        field_config.each_pair do |field, options|
          define_to_field_method field, options
        end
      elsif field_config.respond_to?(:each)
        field_config.each do |field| 
          define_to_field_method field
        end                
      end
    end

  end

end
