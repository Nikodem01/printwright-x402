namespace :admin do
  desc "Grant operator-panel access to an existing designer (ADMIN_EMAIL=...)"
  task grant: :environment do
    designer = Designer.find_by!(email_address: ENV.fetch("ADMIN_EMAIL"))
    designer.update!(admin: true)
    puts "granted operator access to #{designer.email_address}"
  end

  desc "Revoke operator-panel access from an existing designer (ADMIN_EMAIL=...)"
  task revoke: :environment do
    designer = Designer.find_by!(email_address: ENV.fetch("ADMIN_EMAIL"))
    designer.update!(admin: false)
    puts "revoked operator access from #{designer.email_address}"
  end
end
