# Overriding product configuration inside a test.
#
# Tests used to assign ENV in `setup`, which the application no longer reads,
# and which leaked between cases in the same process — a test that forgot to
# restore a value changed the meaning of every test that ran after it. These
# helpers change the same settings the app actually reads and put them back
# afterwards, so order stops mattering.
#
# Most tests need neither: config/printwright.yml has a `test:` section with
# the fixed values the suite asserts against, so the defaults are already right.
module PrintwrightConfigTestHelper
  # Block form, for a single case that needs a different value.
  def with_printwright(**overrides)
    previous = capture_printwright(overrides.keys)
    apply_printwright(overrides)
    yield
  ensure
    apply_printwright(previous)
  end

  # setup form, for a whole test class. Restored by the global teardown below.
  def set_printwright(**overrides)
    @printwright_previous ||= {}
    overrides.each_key do |key|
      @printwright_previous[key] = Rails.configuration.x.printwright[key] unless @printwright_previous.key?(key)
    end
    apply_printwright(overrides)
  end

  def restore_printwright
    apply_printwright(@printwright_previous) if @printwright_previous.present?
    @printwright_previous = nil
  end

  private

  def capture_printwright(keys)
    config = Rails.configuration.x.printwright
    keys.to_h { |key| [ key, config[key] ] }
  end

  def apply_printwright(values)
    config = Rails.configuration.x.printwright
    values.each { |key, value| config[key] = value }
  end
end
