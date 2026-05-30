require 'mongo'
Mongo::Logger.logger.level = Logger::FATAL
$DB = Mongo::Client.new(ENV.fetch('PERF_GATE_MONGO_URL'))
