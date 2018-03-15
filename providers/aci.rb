#
# Cookbook Name:: ldap
# Provider:: aci
#
# Copyright 2014 Riot Games, Inc.
# Author:: Alan Willis <alwillis@riotgames.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

def whyrun_supported?
  true
end

action :set do

  @connectinfo = load_connection_info
  @current_resource = load_current_resource

  permit = new_resource.permit ? 'allow' : 'deny'
  aci_rules = { permission: { permit: permit, rights: new_resource.rights } }

  [ :userdn, :groupdn, :roledn, :targetattr, :ip, :dns ].each do |type|
    ruleset = new_resource.send("#{type}_rule")
    if ruleset
      ruleset.each do |k,v|
        ruleset[k] = v.kind_of?(String) ? [ v ] : v
      end
      aci_rules.merge!({ type => ruleset })
    end
  end

  unless @current_resource.key?(new_resource.label.to_s)
    @current_resource[new_resource.label.to_s] = Hash.new
  end

  old_aci = @current_resource[new_resource.label.to_s][:aci]
  new_aci = compose_aci( new_resource.label, aci_rules )

  converge_if_changed("Setting ACI '#{new_resource.label}' on #{new_resource.distinguished_name}") do
    ldap_entry "#{new_resource.label.gsub(/\ /, '_')}-#{new_resource.distinguished_name}" do
      distinguished_name new_resource.distinguished_name
      host   new_resource.host
      port   new_resource.port
      credentials new_resource.credentials
      databag_name new_resource.databag_name
      append_attributes({ aci: new_aci })
      prune({ aci: old_aci }) if old_aci
    end
  end
end

action :extend do

  @connectinfo = load_connection_info
  @current_resource = load_current_resource
  aci_rules = @current_resource[new_resource.label.to_s]

  if aci_rules.nil?
    Chef::Log.warn("aci-#{new_resource.label.gsub(/\ /, '_')}-#{new_resource.distinguished_name} does not exist, skipping")
  else
    [ :userdn, :groupdn, :roledn, :targetattr, :ip, :dns ].each do |type|
      ruleset = new_resource.send("#{type}_rule")

      if ruleset
        ruleset.each do |equality, value|
          value = value.kind_of?(String) ? [ value ] : value

          if aci_rules.key?(type)
            value.map!{ |v| v !~ /^ldap:\/\/\// ?  "ldap:///#{v}" : v }
            existing = aci_rules[type].key?(equality) ? aci_rules[type][equality] : []
            aci_rules[type][equality] = ( value | existing )
          else
            aci_rules[type] = { equality => value }
          end
        end
      end
    end

    old_aci = @current_resource[new_resource.label.to_s][:aci]
    new_aci = compose_aci( new_resource.label, aci_rules )

    converge_if_changed("Processing ACI '#{new_resource.label}' on #{new_resource.distinguished_name}") do
      ldap_entry "aci-#{new_resource.label.gsub(/\ /, '_')}-#{new_resource.distinguished_name}" do
        distinguished_name new_resource.distinguished_name
        host   new_resource.host
        port   new_resource.port
        credentials new_resource.credentials
        databag_name new_resource.databag_name
        append_attributes({ aci: new_aci })
        prune({ aci: old_aci })
      end
    end
  end
end

action :rescind do

  @connectinfo = load_connection_info
  @current_resource = load_current_resource
  aci_rules = @current_resource[new_resource.label.to_s]

  if aci_rules.nil?
    Chef::Log.warn("ACI '#{new_resource.label}' on #{new_resource.distinguished_name} does not exist, skipping")
  else
    [ :userdn, :groupdn, :roledn, :targetattr, :ip, :dns ].each do |type|
      ruleset = new_resource.send("#{type}_rule")
      if ruleset
        ruleset.each do |equality, value|
          value = value.kind_of?(String) ? [ value ] : value

          if aci_rules.key?(type) and aci_rules[type].key?(equality)
            value.map!{ |v| v !~ /^ldap:\/\/\// ?  "ldap:///#{v}" : v }
            aci_rules[type][equality] -= value
            aci_rules[type].delete(equality) if aci_rules[type][equality].size == 0
          end
        end
      end
    end
  end

  old_aci = @current_resource[new_resource.label.to_s][:aci]
  new_aci = compose_aci( new_resource.label, aci_rules )

  converge_if_changed("Processing ACI '#{new_resource.label}' on #{new_resource.distinguished_name}") do
    ldap_entry "aci-#{new_resource.label.gsub(/\ /, '_')}-#{new_resource.distinguished_name}" do
      distinguished_name new_resource.distinguished_name
      host   new_resource.host
      port   new_resource.port
      credentials new_resource.credentials
      databag_name new_resource.databag_name
      append_attributes({ aci: new_aci })
      prune({ aci: old_aci })
    end
  end
end

action :unset do

  @current_resource = load_current_resource
  aci_rules = @current_resource[new_resource.label.to_s]

  if aci_rules
    converge_if_changed("Removing #{new_resource.label} from #{new_resource.distinguished_name}") do

      old_aci = aci_rules[:aci]

      ldap_entry "aci-#{new_resource.label.gsub(/\ /, '_')}-#{new_resource.distinguished_name}" do
        distinguished_name new_resource.distinguished_name
        host   new_resource.host
        port   new_resource.port
        credentials new_resource.credentials
        databag_name new_resource.databag_name
        prune ({ aci: old_aci })
      end
    end
  end
end

def compose_aci( label, rules )

  aci = Array.new

  if rules.key?(:targetattr)
    rules[:targetattr].each do |equality, attributes|
      attributes = attributes.join(' || ')
      aci.push("(targetattr#{equality}\"#{attributes}\")")
    end
  end

  if rules.key?(:target)
    rules[:target].each do |equality, dn|
      if dn !~ /^ldap:\/\/\//
        dn = "ldap:///" + dn
      end
      aci.push("(target#{equality}\"#{dn}\")")
    end
  end

  if rules.key?(:targetfilter)
    rules[:targetfilter].each do |equality, filter|
      aci.push("(targetattr#{equality}\"#{filter}\")")
    end
  end

  if aci.size == 0
    aci.push("(targetattr=\"*\")")
  end

  aci.push("(version 3.0; acl \"#{label}\";")
  aci.push("#{rules[:permission][:permit]} (#{rules[:permission][:rights].join(',')})" )

  # users, groups and roles
  userspec = Array.new

  [ :userdn, :userdnattr, :groupdn, :groupdnattr, :roledn ].each do |rule|
    if rules.key?(rule)
      rules[rule].each do |equality, dnattrlist|
        dnattrlist.each do |dnattr|
          if [ :userdn, :groupdn, :roledn ].grep(rule).first and dnattr !~ /^ldap:\/\/\//
            dnattr = "ldap:///" + dnattr
          end
          userspec.push("#{rule}#{equality}\"#{dnattr}\"")
        end
      end
    end
  end

  if userspec.size == 0
    userspec.push("userdn=\"ldap:///all\"")
  end

  userspec = userspec.join(' or ')
  aci.push("(#{userspec})")

  # IPs and DNS names
  hostspec = Array.new

  [ :ip, :dns ].each do |rule|
    if rules.key?(rule)
      rules[rule].each do |equality, hosts|
        hosts.each do |host|
          hostspec.push("#{rule}#{equality}\"#{host}\"")
        end
      end
    end
  end

  hostspec = hostspec.join(' or ')
  aci.push("and (#{hostspec})") unless hostspec.empty?

  # Days of the week
  if rules.key?(:dayofweek)
    rules[:dayofweek].each do |equality, days|
      aci.push("and (dayofweek#{equality}\"#{days.join(',')}\"")
    end
  end

  # Time of day
  timespec = Array.new

  if rules.key?(:timeofday)
    rules[:timeofday].each do |equality, time|
      timespec.push("timeofday#{equality}\"#{time}\"")
    end
  end

  timespec = timespec.join(' and ')
  aci.push("and (#{timespec})") unless timespec.empty?

  aci.push(';)')
  aci = aci.join(' ')
  aci
end

def load_current_resource

  require 'orderedhash'

  ldap = Chef::Ldap.new
  @connectinfo = load_connection_info
  @current_resource = OrderedHash.new
  entry = ldap.get_entry( @connectinfo, @new_resource.distinguished_name )

  entry[:aci].each do |aci|

    label = aci.match(/acl \"(.*?)\";/).captures.first
    @current_resource[label] = { aci: aci }

    # permission
    permission = aci.match(/(allow|deny)\s*\((.*?)\)/)
    ( permit, rights ) = permission.captures
    rights = rights.split(/\,\s*/)
    @current_resource[label][:permission] = { permit: permit, rights: rights }

    # everything else

    aci.scan(/(\w+)\s*(\!?>?=?<?)\s*["(](.*?)[")]/) do |rule, equality, value|

      if rule.match(/target|ip|dns|userdn|groupdn|roledn|dayofweek|timeofday|authmethod/)

        case rule
        when 'targetattr'
          value = value.split(/\s*\|\|\s*/)
        when 'dayofweek'
          value = value.split(/\,/)
        end

        if @current_resource[label][rule.to_sym].nil?
          @current_resource[label][rule.to_sym] = OrderedHash.new
          @current_resource[label][rule.to_sym][equality] = [ value ]
        else
          @current_resource[label][rule.to_sym][equality].push(value)
        end
      end
    end
  end
  @current_resource
end

def load_connection_info

  @connectinfo = Hash.new
  @connectinfo.class.module_eval { attr_accessor :host, :port, :credentials, :databag_name, :use_tls }
  @connectinfo.host = new_resource.host
  @connectinfo.port = new_resource.port
  @connectinfo.credentials = new_resource.credentials
  # default databag name is cookbook name
  databag_name = new_resource.databag_name.nil? ? new_resource.cookbook_name : new_resource.databag_name
  @connectinfo.databag_name = databag_name
  @connectinfo.use_tls = new_resource.use_tls
  @connectinfo
end
