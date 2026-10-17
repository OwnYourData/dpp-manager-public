# frozen_string_literal: true

# The access policy the DPP Service classifies this passport by, as the service
# confirmed it, and what it said about the fit: how many attributes no rule
# reaches and how many rules reach nothing (access_policy_report, JSON).
class AddAccessPolicyToPassports < ActiveRecord::Migration[8.1]
  def change
    add_column :passports, :access_policy_id, :string
    add_column :passports, :access_policy_report, :text
  end
end
