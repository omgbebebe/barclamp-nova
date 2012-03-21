#
# Cookbook Name:: nova
# Recipe:: volume
#
# Copyright 2010, Opscode, Inc.
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

include_recipe "nova::config"

volname = node["nova"]["volume"]["volume_name"]

checked_disks = []

node[:crowbar][:disks].each do |disk, value|
  checked_disks << disk if File.exists?("/dev/#{disk}") and node[:crowbar][:disks][disk]["usage"] == "Storage"
end

if checked_disks.empty?
  # only OS disk is exists, will use file storage 
  fname = node["nova"]["volume"]["local_file"]
  fsize = node["nova"]["volume"]["local_size"]

  bash "create local volume file" do
    code "truncate -s #{fsize} #{fname}"
    not_if do
      File.exists?(fname)
    end
  end

  bash "setup loop device for volume" do
    code "losetup -f --show #{fname}"
    not_if "losetup -j #{fname} | grep #{fname}"
  end

  bash "create volume group" do
    code "vgcreate #{volname} `losetup -j #{fname} | cut -f1 -d:`"
    not_if "vgs #{volname}"
  end
  
else
  if node[:nova][:volume][:nova_volume_disks].empty?
    # use first non-OS disk for vg
    dname = "/dev/#{checked_disks.first}"

    bash "create physical volume" do
      code "pvcreate #{dname}"
    end

    bash "create volume group" do
      code "vgcreate #{volname} #{dname}"
      not_if "vgs #{volname}"
    end
  else
    # use this disk list
    disk_list = []
    node[:nova][:volume][:nova_volume_disks].each do |disk|
      disk_list << disk if checked_disks.include?(disk) 
    end

    bash "create physical volume" do
      code "pvcreate #{disk_list.join(' ')}"
    end

    bash "create volume group" do
      code "vgcreate #{volname} #{disk_list.join(' ')}"
      not_if "vgs #{volname}"
    end
  end
end


package "tgt"
nova_package("volume")

# Restart doesn't work correct for this service.
bash "restart-tgt" do
  code <<-EOH
    stop tgt
    start tgt
EOH
  action :nothing
end

service "tgt" do
  supports :status => true, :restart => true, :reload => true
  action :enable
  notifies :run, "bash[restart-tgt]"
end

env_filter = " AND keystone_config_environment:keystone-config-#{node[:nova][:keystone_instance]}"
keystones = search(:node, "recipes:keystone\\:\\:server#{env_filter}") || []
if keystones.length > 0
  keystone = keystones[0]
  keystone = node if keystone.name == node.name
else
  keystone = node
end

keystone_address = Chef::Recipe::Barclamp::Inventory.get_network_by_type(keystone, "admin").address if keystone_address.nil?
keystone_token = keystone["keystone"]["service"]["token"]
keystone_service_port = keystone["keystone"]["api"]["service_port"]
keystone_admin_port = keystone["keystone"]["api"]["admin_port"]
keystone_service_tenant = keystone["keystone"]["service"]["tenant"]
keystone_service_user = "nova" # GREG: Fix this
keystone_service_password = "fredfred" # GREG: Fix this
Chef::Log.info("Keystone server found at #{keystone_address}")

keystone_register "nova volume wakeup keystone" do
  host keystone_address
  port keystone_admin_port
  token keystone_token
  action :wakeup
end

keystone_register "register nova-volume service" do
  host keystone_address
  port keystone_admin_port
  token keystone_token
  service_name "nova-volume"
  service_type "volume"
  service_description "Openstack Nova Volume Service"
  action :add_service
end

public_api_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "public").address
admin_api_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address

keystone_register "register nova-volume endpoint" do
  host keystone_address
  port keystone_admin_port
  token keystone_token
  endpoint_service "nova-volume"
  endpoint_region "RegionOne"
  endpoint_adminURL "http://#{admin_api_ip}:8776/v1/$(tenant_id)s"
  endpoint_internalURL "http://#{admin_api_ip}:8776/v1/$(tenant_id)s"
  endpoint_publicURL "http://#{public_api_ip}:8776/v1/$(tenant_id)s"
#  endpoint_global true
#  endpoint_enabled true
  action :add_endpoint_template
end

