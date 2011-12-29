module Snorby
  module Jobs

    class SnmpJob < Struct.new(:verbose)

      include Snorby::Jobs::CacheHelper

      def perform

        time = Snorby::CONFIG_SNMP[:time].to_f

        Sensor.all.select{|x| x.is_virtual_sensor? and x.ipdir.present?}.each do |sensor|

          @sensor = sensor

          Snorby::CONFIG_SNMP[:oids].each_key do |oid|
            begin
              if Snorby::CONFIG_SNMP[:oids][oid].has_key? "reference"
                value = Snmp.get_value(sensor.ipdir, oid, Snorby::CONFIG_SNMP[:oids][oid]["reference"],
                                                          Snorby::CONFIG_SNMP[:oids][oid]["mult"],
                                                          Snorby::CONFIG_SNMP[:oids][oid]["inverse"])
              else
                value = Snmp.get_value(sensor.ipdir, oid)
              end
              Snmp.create(:sid => sensor.sid, :timestamp => Time.now, :oid => oid, :value => value)
            rescue => e
              logit "#{e}"
            end
          end  

        end  
        
        Snorby::Jobs.snmp.destroy! if Snorby::Jobs.snmp?
        
        Delayed::Job.enqueue(Snorby::Jobs::SnmpJob.new(false), :priority => 1, :run_at => Time.now + time.minutes)
        
      end
      
    end

  end
end  
  