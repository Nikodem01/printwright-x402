module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_designer

    def connect
      set_current_designer || reject_unauthorized_connection
    end

    private
      def set_current_designer
        if session = Session.find_by(id: cookies.signed[:session_id])
          self.current_designer = session.designer
        end
      end
  end
end
