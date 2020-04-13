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
  init = 'terraform init'
  run_local_command(init)
  command = 'terraform apply -auto-approve'
  output = run_local_command(command)
  # TODO: grab data from provisioned resourcces and fill in the nodes step by step from the results of terraform apply
  user = 'user_after_apply'
  password = 'password_after_apply'
  unless vars.nil?
    var_hash = YAML.safe_load(vars)
    node['vars'] = var_hash
  end

  if platform_uses_ssh(platform)
    node = { 'uri' => hostname,
             'config' => { 'transport' => 'ssh', 'ssh' => { 'user' => '#{user}', 'password' => '#{password}', 'host-key-check' => false } },
             'facts' => { 'provisioner' => 'terraform', 'platform' => platform } }
    group_name = 'ssh_nodes'
  else
    node = { 'uri' => hostname,
             'config' => { 'transport' => 'winrm', 'winrm' => { 'user' => 'Administrator', 'password' => '#{password}', 'ssl' => false } },
             'facts' => { 'provisioner' => 'terraform', 'platform' => platform } }
    group_name = 'winrm_nodes'
  end
  inventory_full_path = File.join(inventory_location, 'inventory.yaml')
  inventory_hash = get_inventory_hash(inventory_full_path)
  add_node_to_group(inventory_hash, node, group_name)
  File.open(inventory_full_path, 'w') { |f| f.write inventory_hash.to_yaml }
  { status: 'ok', node_name: hostname, node: node }
end

def tear_down(node_name, inventory_location)
  include PuppetLitmus::InventoryManipulation
  # TO DO: terraform destroy

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
raise 'specify a platform when provisioning' if action == 'provision' && platform.nil?

unless node_name.nil? ^ platform.nil?
  case action
  when 'tear_down'
    raise 'specify only a node_name, not platform, when tearing down'
  when 'provision'
    raise 'specify only a platform, not node_name, when provisioning'
  else
    raise 'specify only one of: node_name, platform'
  end
end

begin
  result = provision(platform, inventory_location, vars) if action == 'provision'
  result = tear_down(node_name, inventory_location) if action == 'tear_down'
  puts result.to_json
  exit 0
rescue StandardError => e
  puts({ _error: { kind: 'facter_task/failure', msg: e.message } }.to_json)
  exit 1
end
