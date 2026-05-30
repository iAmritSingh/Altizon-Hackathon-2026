class DemoReport
  def self.main(license_key, task_id, args, ctx)
    # REGRESSION: dropped the selective license_key + machine_key filter.
    # Now every pph_slot document is scanned instead of just this tenant's machines.
    pipeline = [
      { "$match" => { "type" => "pph_slot" } },
      { "$group" => { "_id" => "$machine_key", "n" => { "$sum" => 1 } } }
    ]
    $DB[:generic_events].aggregate(pipeline).to_a
  end
end
