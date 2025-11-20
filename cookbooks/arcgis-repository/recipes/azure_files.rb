#
# Cookbook:: arcgis-repository
# Recipe:: azure_files
#
# Copyright 2025 Esri
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
require 'pathname'

include_recipe 'arcgis-repository::azure_cli'

# Create archives directory
directory node['arcgis']['repository']['local_archives'] do
  mode '0755' if node['platform'] != 'windows'
  recursive true
  action :create
end

local_archives = node['arcgis']['repository']['local_archives']
account_name = node['arcgis']['repository']['server']['account_name']
container_name = node['arcgis']['repository']['server']['container_name']
auth_mode = node['arcgis']['repository']['server']['auth_mode']
az = node['platform'] == 'windows' ? 'az' : ::File.join(node['arcgis']['repository']['azure_cli']['install_dir'], 'bin', 'az')

if auth_mode == 'key'
  env = {
    'AZURE_STORAGE_ACCOUNT' => account_name,
    'AZURE_STORAGE_KEY' => node['arcgis']['repository']['server']['account_key']
  }
else # auth_mode == 'login'
  env = {}
  client_id = node['arcgis']['repository']['server']['client_id']
  # Login to Azure CLI using system-assigned or user-assigned managed identity
  execute 'Login to Azure CLI' do
    command client_id.nil? ? "#{az} login --identity" : "az login --identity --client-id #{client_id}"
  end
end

# Download individual files

node['arcgis']['repository']['files'].each do |filename, props|
  blob_name = props['subfolder'].nil? ? filename : ::File.join(props['subfolder'], filename)
  path = ::File.join(local_archives, filename)

  execute "Download #{filename}" do
    command "#{az} storage blob download --file #{path} --account-name #{account_name} --container-name #{container_name} --name #{blob_name} --auth-mode #{auth_mode} --no-progress --output none"
    environment env
    not_if { ::File.exist?(path) }
  end
end

# Download patches

patch_notification = node['arcgis']['repository']['patch_notification']
temp_dir = Chef::Config['file_cache_path']
temp_dst = patch_notification['subfolder'].nil? ? temp_dir : 
           File.join(temp_dir, patch_notification['subfolder'])
dst = node['arcgis']['repository']['local_patches']

# Create patches directory
directory dst do
  mode '0755' if node['platform'] != 'windows'
  recursive true
  not_if { patch_notification['subfolder'].nil? }  
  action :create
end

if node['platform'] == 'windows'
  directory temp_dst do
    recursive true
    not_if { patch_notification['subfolder'].nil? }
    action :create
  end
else
  directory Pathname.new(temp_dst).parent do
    recursive true
    not_if { patch_notification['subfolder'].nil? }
    action :create
  end
end

# Create symbolic link to patches directory
link temp_dst do
  to dst
  link_type :symbolic
  not_if { patch_notification['subfolder'].nil? }
  action :create
end

patch_notification['patches'].each do |patch|
  execute "Download patch #{patch}" do
    command "#{az} storage blob download-batch --destination #{temp_dir} --pattern  #{patch_notification['subfolder']}/#{patch} --account-name #{account_name} --source #{container_name} --auth-mode #{auth_mode} --overwrite true --no-progress --output none"
    environment env
    live_stream true
    not_if { patch_notification['subfolder'].nil? }
  end
end
