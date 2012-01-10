class SensorsController < ApplicationController

  respond_to :html, :xml, :json, :js, :csv

  #before_filter :require_administrative_privileges, :except => [:index, :update_name]
  before_filter :create_virtual_sensors, :only => [:index]

  before_filter :default_values, :except => [:index, :new, :create]

  authorize_resource :except => :index
  
  # It returns a sensor's hierarchy tree
  def index
    hierarchy = Sensor.root.hierarchy(10)
    if hierarchy.nil?
      @sensors = []
    else
      @sensors ||= hierarchy.flatten.compact unless hierarchy.nil?
    end
  end

  def show
    @range  = 'last_24'

    cache = Cache.last_24(Time.now.yesterday, Time.now).all(:sensor => @sensor.real_sensors)

    event_values(cache)
    snmp_values
    traps_values

    if @sensor_metrics.last
      @axis = @sensor_metrics.last[:range].join(',')
    elsif @metrics.first.last
      @axis = @metrics.first.last[:range].join(',')
    end

  end

  def update_name
    @sensor.update(:name => params[:name]) if @sensor
    render :text => @sensor.name
  end

  def update_ip
    @sensor.update(:ipdir => params[:ip]) if @sensor
    render :text => @sensor.ipdir
  end

  def update_dashboard_rules
    @events = @sensor.events(:order => [:timestamp.desc], :limit => 10)
    @traps  = @sensor.traps(:order => [:timestamp.desc], :limit => 5)
  end

  def update_dashboard_load
  end
  
  def update_dashboard_hardware
  end

  # It destroys a sensor and its childs.
  def destroy
    @sensor.destroy
    respond_to do |format|
      format.html { redirect_to(sensors_path) }
      format.xml  { head :ok }
    end
  end

  def new
    @sensor = Sensor.new
    render :layout => false
	end

  def create
    params[:sensor][:domain]=true if params[:sensor][:domain].nil?
    @sensor = Sensor.create(params[:sensor])
    @sensor.update(:parent => Sensor.root, :domain => true)

    redirect_to sensors_path
  end

  def edit
    @role = @sensor.chef_role
  end

  def update
    @role = @sensor.chef_role

    params_role = params[:role]

    params[:sensor] ||= {:name => @sensor.name}

    params_role[:redBorder][:snort].each do |key, value|
      if value.class == ActiveSupport::HashWithIndifferentAccess
        value.each do |key2, value2|
          if key == "preprocessors"
            value2["mode"].present? ? @role.override_attributes["redBorder"]["snort"][key][key2] = to_boolean(value2) : @role.override_attributes["redBorder"]["snort"][key].delete(key2)
          else
            value2.present? ? @role.override_attributes["redBorder"]["snort"][key][key2] = to_boolean(value2) : @role.override_attributes["redBorder"]["snort"][key].delete(key2)
          end
        end
      else
        value.present? ? @role.override_attributes["redBorder"]["snort"][key] = value : @role.override_attributes["redBorder"]["snort"].delete(key)
      end
    end

    params_role[:redBorder][:barnyard2][:syslog_servers].present? ? @role.override_attributes["redBorder"]["barnyard2"]["syslog_servers"] = params_role[:redBorder][:barnyard2][:syslog_servers].split(/\s*,\s*/) : @role.override_attributes["redBorder"]["barnyard2"].delete("syslog_servers")

    if @sensor.update(params[:sensor]) and @role.save
      redirect_to(edit_sensor_path, :notice => 'Sensor was successfully updated.')
    else
      redirect_to(edit_sensor_path, :notice => 'Was an error updating the sensor.')
    end
  end

  # Method used when a sensor is has been dragged and dropped to another sensor.
  def update_parent
    @sensor.update(:parent_sid => params[:p_sid]) if @sensor
    respond_to do |format|
      format.html
      format.js
    end
  end

  private

    def create_virtual_sensors
      sensors1 = Sensor.all(:domain => false, :parent_sid => nil)
      sensors1.each do |sensor|
        if sensor.hostname.include? ':'
          pname = /([^:]+):/.match(sensor.hostname)[1]
        else
          pname = sensor.hostname
        end
        p_sensor = Sensor.first(:name => pname.capitalize, :hostname => pname, :domain => true)
        if p_sensor.nil?
          p_sensor = Sensor.create(:name => pname.capitalize, :hostname => pname, :domain => true, :parent => Sensor.root)
          node     = p_sensor.chef_node
          node.run_list("role[#{p_sensor.chef_name}]")
          node.tags << "inilizialized"
          node.save
        end
        sensor.update(:parent => p_sensor)
      end

      sensors2 = Sensor.all(:domain => true, :ipdir => nil).select{|x| x.is_virtual_sensor?}
      sensors2.each do |sensor|
        node = sensor.chef_node
        sensor.update(:ipdir => node[:ipaddress])
      end

      begin
        Sensor.root.chef_role
      rescue
        Sensor.repair_chef_db
      end

      # Needed to reload the object. Without that, index need to be reload twice to view the sensors created.
      redirect_to sensors_path if sensors1.present? || sensors2.present?
    end

    def default_values
      @sensor = (Sensor.get(params[:sensor_id]) or Sensor.get(params[:id]))
      @role   = @sensor.chef_role unless @sensor.nil?
      @node   = @sensor.chef_node unless @sensor.nil?
    end

    def event_values (cache)
      @src_metrics = cache.src_metrics
      @dst_metrics = cache.dst_metrics

      @tcp  = cache.protocol_count(:tcp, @range.to_sym)
      @udp  = cache.protocol_count(:udp, @range.to_sym)
      @icmp = cache.protocol_count(:icmp, @range.to_sym)

      @signature_metrics = cache.signature_metrics

      @high   = cache.severity_count(:high, @range.to_sym)
      @medium = cache.severity_count(:medium, @range.to_sym)
      @low    = cache.severity_count(:low, @range.to_sym)

      @event_count = @high.sum + @medium.sum + @low.sum

      @sensor_metrics = cache.sensor_metrics(@range.to_sym)
    end

    def traps_values
      @trap_count = @sensor.traps(:timestamp.gte => Time.now.yesterday).size
    end

    def snmp_values
      @snmp = Snmp.last_24(Time.now.yesterday, Time.now).all(:sensor => @sensor.virtual_sensors)
      @metrics = @snmp.metrics(@range.to_sym)

      @high_snmp    = @snmp.severity_count(:high, @range.to_sym)
      @medium_snmp  = @snmp.severity_count(:medium, @range.to_sym)
      @low_snmp     = @snmp.severity_count(:low, @range.to_sym)
      
      @snmp_count = @high_snmp.sum + @medium_snmp.sum + @low_snmp.sum
    end

    def to_boolean(value)
      case value
      when "true"
        return true
      when {"mode" => "true"}
        return {"mode" => true}
      when "false"
        return false
      when {"mode" => "false"}
        return {"mode" => false}
      else
        return value
      end
    end

end
