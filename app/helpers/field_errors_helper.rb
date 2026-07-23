module FieldErrorsHelper
  # Ties a validation message to its own field for assistive tech. Returns the
  # error paragraph (id'd, announced) plus the aria attributes to spread onto
  # the input, so a screen reader reads the message when focus lands on the
  # field. When the attribute has no error, both are inert.
  def field_error(model, attr)
    messages = model.errors[attr]
    return FieldError.new(nil, {}) if messages.blank?

    id = "#{model.model_name.param_key}_#{attr}_error"
    paragraph = tag.p(messages.to_sentence, class: "field-error", id: id)
    FieldError.new(paragraph, { invalid: true, describedby: id })
  end

  FieldError = Struct.new(:paragraph, :aria)
end
