#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bolt_spec/run'
require 'json'
require 'net/http'
require 'yaml'
require 'puppet_litmus'
require_relative '../lib/task_helper'

DEFAULT_CONFIG_DATA ||= { 'modulepath' => File.join(Dir.pwd, 'spec', 'fixtures', 'modules') }

def provision(platform, inventory_location, vars)
  include ::BoltSpec::Run
  include PuppetLitmus::InventoryManipulation

  if vars.nil? 
    vars = {}   
    vars['dir'] = Dir.pwd
    vars['state'] = 'terraform.tfstate'
  end

  run_task('terraform::initialize','localhost', {'dir' => "#{vars['dir']}"}, config: DEFAULT_CONFIG_DATA)
  run_task('terraform::apply','localhost', {'dir' => "#{vars['dir']}"}, config: DEFAULT_CONFIG_DATA)


  tfstate_data=JSON.parse(File.read(vars['state']))

  nodes = []
  tfstate_data['resources'].each do |machines|
    machines['instances'].each do |machine|
      if machine['attributes']['ssh_config']
        machine['attributes']['ssh_config'].each do |config|
         user = config['user']
         hostname = config['host']+":"+config['port']

         key_file_name = "#{Dir.pwd}/#{machines['name']}.key" 
         File.write(key_file_name, config['private_key'])
         File.chmod(0600, key_file_name)
         private_key = key_file_name

         node = { 'uri' => hostname,
                  'config' => { 'transport' => 'ssh', 'ssh' => { 'user' => user, 'private-key' => private_key, 'host-key-check' => false, 'port' => config['port'].to_i, 'run-as' => 'root' } },
                 'facts' => { 'provisioner' => 'terraform_provision::terraform' } }
         group_name = 'ssh_nodes'
         nodes << {:node => node,:group => group_name}
        end
      end
    end
  end

  inventory_full_path = File.join(inventory_location, 'inventory.yaml')
  inventory_hash = get_inventory_hash(inventory_full_path)

  nodes.each do |item|
    add_node_to_group(inventory_hash, item[:node], item[:group])
  end
  File.open(inventory_full_path, 'w') { |f| f.write inventory_hash.to_yaml }

  { status: 'ok' }
end

def tear_down(node_name, inventory_location, vars)
  include ::BoltSpec::Run
  include PuppetLitmus::InventoryManipulation

  if vars.nil? 
    vars = {}   
    vars['dir'] = Dir.pwd
  end

  run_task('terraform::destroy','localhost', {'dir' => "#{vars['dir']}"}, config: DEFAULT_CONFIG_DATA)

  inventory_full_path = File.join(inventory_location, 'inventory.yaml')
  if File.file?(inventory_full_path)
    inventory_hash = inventory_hash_from_inventory_file(inventory_full_path)
    remove_node(inventory_hash, node_name)
  end
  puts "Removed #{node_name}"
  File.open(inventory_full_path, 'w') { |f| f.write inventory_hash.to_yaml }
  { status: 'ok' }
end

params = JSON.parse(STDIN.read)
action = params['action']
platform = params['platform'] # required by litmus on provision run
node_name = params['node_name'] # required by litmus on tear_down run
inventory_location = sanitise_inventory_location(params['inventory'])
vars = params['vars']
raise 'specify a node_name when tearing down' if action == 'tear_down' && node_name.nil?

begin
  result = provision(platform, inventory_location, vars) if action == 'provision'
  result = tear_down(node_name, inventory_location, vars) if action == 'tear_down'
  puts result.to_json
  exit 0
rescue StandardError => e
  puts({ _error: { kind: 'facter_task/failure', msg: e.message } }.to_json)
  exit 1
end
