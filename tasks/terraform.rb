#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'yaml'
require 'puppet_litmus'
require_relative '../lib/task_helper'

def provision(platform, inventory_location, vars)
  include PuppetLitmus::InventoryManipulation

  # this runs inside the module directory so there is a need for the tf files to be there
  # the terraform init command will ensure that all plugins will be prepared before applying the tf files
  init = 'terraform init -input=false'
  run_local_command(init)
  command = 'terraform apply -auto-approve'
  output = run_local_command(command)
  # TODO: grab data from provisioned resources tfstate and fill in the nodes step by step from the results of terraform apply
  raise "Failed to load data from terraform tfstate file" unless File.exist?('terraform.tfstate')
  tfstate_data=JSON.parse(File.read('terraform.tfstate'))
  unless vars.nil?
    var_hash = YAML.safe_load(vars)
    node['vars'] = var_hash
  end

  nodes = []
  tfstate_data['resources'].each do |machines|
    machines['instances'].each do |machine|
      if machine['attributes']['ssh_config']
        machine['attributes']['ssh_config'].each do |config|
         user = config['user']
         hostname = config['host']+":"+config['port']
         private_key = '~/.vagrant.d/insecure_private_key'
         node = { 'uri' => hostname,
                  'config' => { 'transport' => 'ssh', 'ssh' => { 'user' => user, 'private-key' => private_key, 'host-key-check' => false, 'port' => config['port'].to_i, 'run-as' => 'root' } },
                 'facts' => { 'provisioner' => 'terraform_provision::terraform' } }
         group_name = 'ssh_nodes'
         nodes << {:node => node,:group => group_name}
        end
       else
         node = { 'uri' => hostname,
                  'config' => { 'transport' => 'winrm', 'winrm' => { 'user' => 'Administrator', 'password' => '#{password}', 'ssl' => false } },
                  'facts' => { 'provisioner' => 'terraform_provision::terraform' } }
         group_name = 'winrm_nodes'
       end
    end
  end
  inventory_full_path = File.join(inventory_location, 'inventory.yaml')
  inventory_hash = get_inventory_hash(inventory_full_path)
  nodes.each do |item|
    add_node_to_group(inventory_hash, item[:node], item[:group])
  end
  File.open(inventory_full_path, 'w') { |f| f.write inventory_hash.to_yaml }
  { status: 'ok', nodes: nodes }
end

def tear_down(node_name, inventory_location)
  include PuppetLitmus::InventoryManipulation
  command = 'terraform destroy -auto-approve'
  output = run_local_command(command)
  
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
platform = params['platform']
action = params['action']
node_name = params['node_name']
inventory_location = sanitise_inventory_location(params['inventory'])
vars = params['vars']
raise 'specify a node_name when tearing down' if action == 'tear_down' && node_name.nil?

begin
  result = provision(platform, inventory_location, vars) if action == 'provision'
  result = tear_down(node_name, inventory_location) if action == 'tear_down'
  puts result.to_json
  exit 0
rescue StandardError => e
  puts({ _error: { kind: 'facter_task/failure', msg: e.message } }.to_json)
  exit 1
end
