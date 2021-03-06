class ApplicationController < ActionController::Base
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :exception

  CurrentUser = Struct.new(:session) do

    # returning the actual Student ActiveRecord object here might require extra SQL calls
    #  the two values pulled from the session are already supplied when Canvas POSTs to
    #  launch a session of the app.
    #
    #  If this must be extended with the ActiveRecord object, perhaps use '.user' or '.local_user'

    def canvas_id
      session && session['canvas'] && session['canvas']['user_id']
    end

    def user_name
      session && session['canvas'] && session['canvas']['user_name']
    end

    def user_roles
      session && session['canvas'] && session['canvas']['user_roles']
    end
  end

  # utilities
  def current_user
    CurrentUser.new(session)
  end

end
