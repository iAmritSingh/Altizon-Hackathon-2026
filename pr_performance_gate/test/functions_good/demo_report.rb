class DemoReport
  def self.main(license_key, task_id, args, ctx)
    pipeline = [
      { "$match" => { "license_key" => license_key, "machine_key" => { "$in" => args["machine_keys"] }, "type" => "pph_slot" } },
      { "$group" => { "_id" => "$machine_key", "n" => { "$sum" => 1 } } }
    ]
    $DB[:generic_events].aggregate(pipeline).to_a
  end
end
