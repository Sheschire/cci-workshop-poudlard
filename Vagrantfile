# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Dockerwarts N°1 — three Ubuntu 24.04 LTS nodes on a VirtualBox host-only
# network (192.168.56.0/24), all Docker Swarm managers.
#
# The VMs are deliberately *bare*: Vagrant only creates them and installs
# python3 (required by Ansible). Every piece of configuration — Docker, the
# firewall, NFS, Keepalived, the Swarm itself — is done by Ansible
# (`make provision`), so that the exact same playbook provisions cloud VMs.
# See ADR-0002.
#
# Sizing is driven by the environment: NODE_MEM / NODE_CPU (see .env.example).
#   PROFILE=full → NODE_MEM=6144   PROFILE=lite → NODE_MEM=4096

NODES = [
  { name: "node1", ip: "192.168.56.11" },
  { name: "node2", ip: "192.168.56.12" },
  { name: "node3", ip: "192.168.56.13" }
].freeze

NODE_MEM = (ENV["NODE_MEM"] || "6144").to_i
NODE_CPU = (ENV["NODE_CPU"] || "4").to_i
BOX      = ENV["VAGRANT_BOX"] || "bento/ubuntu-24.04"

Vagrant.configure("2") do |config|
  config.vm.box = BOX
  # The shared folder is unused (Ansible drives everything over SSH) and costs
  # a VirtualBox Guest Additions dependency: disable it.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  NODES.each_with_index do |node, index|
    config.vm.define node[:name] do |vm|
      vm.vm.hostname = node[:name]
      # Host-only network: the lab subnet, also carrying the Keepalived VIP.
      vm.vm.network "private_network", ip: node[:ip], netmask: "255.255.255.0"

      vm.vm.provider "virtualbox" do |vb|
        vb.name   = "dockerwarts-#{node[:name]}"
        vb.memory = NODE_MEM
        vb.cpus   = NODE_CPU
        # Nested paging + a sane clock keep Galera/Cassandra happy.
        vb.customize ["modifyvm", :id, "--nested-paging", "on"]
        vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
        # 40 GB is the CDC target; bento boxes ship a resizable 64 GB disk.
      end

      # Minimal bootstrap so that Ansible can connect and run.
      vm.vm.provision "shell", name: "bootstrap", privileged: true, inline: <<~SHELL
        set -Eeuo pipefail
        if ! command -v python3 >/dev/null 2>&1; then
          export DEBIAN_FRONTEND=noninteractive
          apt-get update -qq
          apt-get install -y -qq python3 python3-apt
        fi
        # /etc/hosts entries let the nodes reach each other by name before
        # any DNS exists (Galera/Cassandra/ES seeds use Swarm DNS, but Ansible
        # and the operator benefit from stable names).
        for entry in "192.168.56.11 node1" "192.168.56.12 node2" "192.168.56.13 node3"; do
          grep -qxF "$entry" /etc/hosts || echo "$entry" >> /etc/hosts
        done
      SHELL

      # Ansible runs once, on the last node, against the whole inventory:
      # the Swarm join step needs every host reachable in a single play.
      if index == NODES.length - 1
        vm.vm.provision "ansible", run: "never" do |ansible|
          ansible.playbook       = "ansible/playbooks/site.yml"
          ansible.inventory_path = "ansible/inventory/hosts.yml"
          ansible.limit          = "all"
          ansible.compatibility_mode = "2.0"
        end
      end
    end
  end
end
