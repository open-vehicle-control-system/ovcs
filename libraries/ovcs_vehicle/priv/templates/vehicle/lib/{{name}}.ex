defmodule <%= @module %> do
  @moduledoc """
  Top-level entry point for the <%= @upper %> vehicle package.
  """
  @behaviour OvcsVehicle

  @impl OvcsVehicle
  def name, do: "<%= @upper %>"
  @impl OvcsVehicle
  def vms, do: <%= @module %>.Vms.Composer
<%= if @infotainment do %>  @impl OvcsVehicle
  def infotainment, do: <%= @module %>.Infotainment.Composer
<% end %>  @impl OvcsVehicle
  def can_config_otp_app, do: :<%= @name %>
  @impl OvcsVehicle
  def nerves_target(:vms), do: :<%= @vms_target %>
<%= if @infotainment do %>  def nerves_target(:infotainment), do: :<%= @infotainment_target %>
<% end %>end
