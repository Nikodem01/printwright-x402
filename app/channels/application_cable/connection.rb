module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_designer

    def connect
      set_current_designer || reject_unauthorized_connection
    end

    private
      # Rodauth stores the authenticated account id in the Rails session; resolve
      # the designer from the encrypted session cookie.
      def set_current_designer
        account_id = cookies.encrypted[session_cookie_key]&.dig("account_id")
        if account_id && (designer = Designer.find_by(id: account_id))
          self.current_designer = designer
        end
      end

      def session_cookie_key
        Rails.application.config.session_options[:key] || "_printwright_x402_session"
      end
  end
end
