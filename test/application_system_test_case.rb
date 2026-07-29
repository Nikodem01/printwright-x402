require "test_helper"

# Headless Chrome shares two cores with Postgres and the Rails server on a CI
# runner. At 5s an `assert_text` could lose to CPU contention rather than to a
# real bug — observed once locally when suites ran concurrently. Waits are
# polled, so a longer ceiling costs a green run nothing and only buys time for a
# loaded one.
Capybara.default_max_wait_time = 10
Selenium::WebDriver.logger.level = :warn

module ExpectedSeleniumModal
  attr_reader :modal_expected

  def accept_modal(...)
    @modal_expected = true
    super
  ensure
    @modal_expected = false
  end

  def dismiss_modal(...)
    @modal_expected = true
    super
  ensure
    @modal_expected = false
  end
end

Capybara::Selenium::Driver.prepend(ExpectedSeleniumModal)

# Under CPU contention Chrome can occasionally return from WebDriver's click
# command without dispatching a click event. Capybara cannot retry that case
# because the driver reported success. Record receipt in the page before each
# plain click and retry only when the event never reached the document.
module ReliableChromeClicks
  RECEIPT_KEY = "printwright-capybara-click"
  SUBMISSION_KEY = "printwright-capybara-form-submit"
  SUBMISSION_COMPLETED_KEY = "printwright-capybara-form-completed"
  MAX_ATTEMPTS = 3

  def click(keys = [], **options)
    ordinary_click = keys.empty? && (options.empty? || options == { offset: :center })
    return super unless ordinary_click
    return super if driver.modal_expected
    element_kind = driver.evaluate_script(<<~JS, self)
      (() => {
        const element = arguments[0];
        if (element.tagName === "OPTION") return "option";
        if (element.form && element.matches(
          "button:not([type]), button[type='submit'], input[type='submit'], input[type='image']"
        )) return "form";
        if (element.tagName === "A") return "link";
        return "click";
      })()
    JS
    return super if element_kind == "option"

    wait_for_stimulus_action
    receipt = "#{Process.pid}-#{object_id}-#{Process.clock_gettime(Process::CLOCK_MONOTONIC)}"
    previous_url = driver.current_url
    expects_navigation = element_kind == "link" && driver.evaluate_script(<<~JS, self, previous_url)
      (() => {
        const element = arguments[0];
        return element.href !== arguments[1] &&
          !element.hasAttribute("download") &&
          element.dataset.turbo !== "false" &&
          (!element.target || element.target === "_self");
      })()
    JS

    result = nil
    MAX_ATTEMPTS.times do |attempt|
      receipt_args = [
        self, RECEIPT_KEY, SUBMISSION_KEY, SUBMISSION_COMPLETED_KEY, receipt
      ]
      begin
        driver.execute_script(<<~JS, *receipt_args)
          window.sessionStorage.removeItem(arguments[1]);
          window.sessionStorage.removeItem(arguments[2]);
          window.sessionStorage.removeItem(arguments[3]);
          const element = arguments[0];
          const markReceipt = () => window.sessionStorage.setItem(arguments[1], arguments[4]);
          const markSubmit = () => window.sessionStorage.setItem(arguments[2], arguments[4]);
          const markCompleted = () => window.sessionStorage.setItem(arguments[3], arguments[4]);
          const submitsForm = #{element_kind == "form"};
          const receiptTarget = submitsForm ? element.form : element;
          const receiptEvent = submitsForm ? "submit" : "click";
          receiptTarget.addEventListener(receiptEvent, markReceipt, { once: true });
          let submittedForm = submitsForm ? element.form : null;
          document.addEventListener("submit", (event) => {
            submittedForm = event.target;
            markSubmit();
          }, { capture: true, once: true });
          let activeSubmission = null;
          document.addEventListener("turbo:submit-start", (event) => {
            if (event.target === submittedForm) {
              activeSubmission = event.detail.formSubmission;
            }
          });
          document.addEventListener("turbo:submit-end", (event) => {
            if (event.detail.formSubmission === activeSubmission && event.detail.fetchResponse) {
              markCompleted();
            }
          });
          window.addEventListener("pagehide", markCompleted, { once: true });
        JS
      rescue ::Selenium::WebDriver::Error::StaleElementReferenceError
        return result if attempt.positive?

        raise
      end

      result = attempt.zero? ? super : driver.execute_script("arguments[0].click()", self)
      begin
        return result if driver.current_url != previous_url

        received = action_receipt?(RECEIPT_KEY, receipt)
        submitted = action_receipt?(SUBMISSION_KEY, receipt)
        completed = !submitted || wait_for_submission_completion(receipt)
        navigated = !expects_navigation || wait_for_navigation_from(previous_url)
        return result if received && completed && navigated
      rescue ::Selenium::WebDriver::Error::UnexpectedAlertOpenError
        return result
      end
    end

    # Seen when the machine is loaded — one headless Chrome per parallel worker,
    # plus Puma and Postgres, and a click can miss its deadline through no fault
    # of the page. Say so, so it is not mistaken for a broken element.
    raise "Chrome did not complete a click after #{MAX_ATTEMPTS} attempts " \
          "(each waiting up to #{Capybara.default_max_wait_time}s). If other servers or browsers " \
          "are running alongside the suite, this is usually contention rather than the page."
  end

  private

  def action_receipt?(key, receipt)
    driver.evaluate_script(
      "window.sessionStorage.getItem(arguments[0]) === arguments[1]",
      key,
      receipt
    )
  end

  def wait_for_submission_completion(receipt)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5

    loop do
      return true if action_receipt?(SUBMISSION_COMPLETED_KEY, receipt)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end

  def wait_for_navigation_from(previous_url)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1

    loop do
      return true if driver.current_url != previous_url
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end

  def wait_for_stimulus_action
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time

    until driver.evaluate_script(<<~JS, self)
      (() => {
        const element = arguments[0];
        const actions = (element.dataset.action || "").trim().split(/\\s+/).filter(Boolean);
        const clickActions = actions.filter((action) => {
          const event = action.includes("->") ? action.split("->")[0] : "click";
          return event === "click" || event.startsWith("click.");
        });
        if (clickActions.length === 0) return true;
        if (!window.Stimulus) return false;

        return clickActions.every((action) => {
          const identifier = action.split("->").pop().split("#")[0];
          let scope = element;
          while (scope) {
            const controllers = (scope.dataset.controller || "").split(/\\s+/);
            if (controllers.includes(identifier)) {
              return Boolean(window.Stimulus.getControllerForElementAndIdentifier(scope, identifier));
            }
            scope = scope.parentElement;
          }
          return false;
        });
      })()
    JS
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise "Stimulus action was not ready before click"
      end

      sleep 0.05
    end
  end
end

Capybara::Selenium::ChromeNode.prepend(ReliableChromeClicks)

# JS-capable base: headless Chrome for flows that run Stimulus (checkout).
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 800 ] do |options|
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
  end

  # Loading webmock/minitest (any test file that stubs HTTP) disables net
  # connect process-wide with allow_localhost false, which also blocks
  # chromedriver on 127.0.0.1:9515. Whether a browser test survives then
  # depends on whether a test that re-allows localhost happened to run first —
  # order-dependent, so it passed locally and failed in CI on a different seed.
  # Every browser test needs its driver reachable; assert that up front.
  setup do
    if defined?(WebMock)
      WebMock.disable_net_connect!(allow_localhost: true)
      WebMock.stub_request(:get, %r{https://testnet\.mirrornode\.hedera\.com/api/v1/topics/.+/messages})
        .to_return(body: { messages: [] }.to_json)
    end
  end
end

# No-JS base: plain form flows (designer publish, verify page) don't need a
# browser — rack_test keeps them fast and dependency-free.
class RackSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :rack_test
end
