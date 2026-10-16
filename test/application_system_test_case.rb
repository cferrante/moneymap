require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  # Stimulus attaches controllers after the page's JavaScript loads, so a click
  # right after a page load can land before the controller exists and silently do
  # nothing, which makes a test flaky. Call this before interacting with any
  # element whose behavior comes from a Stimulus controller. Capybara's
  # synchronize retries the block until it passes or the wait time runs out.
  def wait_for_stimulus_controller(identifier)
    page.document.synchronize do
      connected = page.evaluate_script(<<~JS)
        (() => {
          const element = document.querySelector("[data-controller~='#{identifier}']")
          return !!(element && window.Stimulus?.getControllerForElementAndIdentifier(element, "#{identifier}"))
        })()
      JS
      raise Capybara::ExpectationNotMet, "#{identifier} controller not connected yet" unless connected
    end
  end
end
