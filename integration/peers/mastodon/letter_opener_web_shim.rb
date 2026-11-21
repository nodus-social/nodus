# Mastodon's official image is built with `bundle install --without
# development test`, but this lab has to boot it with RAILS_ENV=development:
# production forces https (config/initializers/1_hosts.rb,
# config/environments/production.rb `config.force_ssl`) and the peers only
# speak plain HTTP on the docker network.
#
# Two development-only files reference the letter_opener_web gem, which is in
# the excluded bundle group:
#
#   config/initializers/content_security_policy.rb:68
#   config/routes.rb:52  (mount LetterOpenerWeb::Engine)
#
# Defining the two constants they touch is enough for the app to boot. Nothing
# serves /letter_opener and no mail is delivered in the lab, so the shim is
# inert apart from satisfying the constant lookup. It is mounted as
# config/initializers/0_letter_opener_web_shim.rb, which loads before
# content_security_policy.rb and before routes are drawn.
module LetterOpenerWeb
  class Engine < Rails::Engine
  end

  class LettersController
    # The CSP initializer installs a policy block and an after_action on the
    # controller. Plain class methods keep both working without the gem. The
    # class deliberately does not inherit from ActionController::Base: that
    # fires ActionController's `inherited` hook, which constantizes every
    # helper (AccountsHelper, ...) during boot, before Zeitwerk can autoload
    # app/helpers, and the app fails with `uninitialized constant`.
    def self.content_security_policy(&block)
      nil
    end

    def self.after_action(*args, &block)
      nil
    end
  end
end
