namespace :imports do
  desc "Recover the import quota of an identity left by a stopped request (EMAIL=...)"
  task recover_admissions: :environment do
    identity = Identity.find_by!(email_address: ENV.fetch("EMAIL"))
    admissions = Account::Import::Admission.unfinished.where(identity: identity).order(:created_at)
    puts "No unfinished admissions for #{identity.email_address}." if admissions.none?

    failed = false
    admissions.each do |admission|
      if admission.recover.finished_at
        puts "Recovered admission #{admission.id}."
      else
        failed = true
        puts "Admission #{admission.id} keeps its charge: deleting the failed import's objects did not complete."
      end
    rescue => error
      failed = true
      puts "Admission #{admission.id} kept: #{error.message}."
    end
    abort if failed
  end
end
