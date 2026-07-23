class Designer::NotificationsController < Designer::BaseController
  # Bounded to the newest 100: no pagination pattern exists yet elsewhere in
  # the designer workspace to reuse, and a durable stream older than this is
  # still fully available via the linked recovery surfaces (Sales, Payouts,
  # Webhooks, model edit, Identity).
  RECENT_LIMIT = 100

  def show
    @notifications = current_designer.seller_notifications.recent.limit(RECENT_LIMIT)
  end

  def mark_all_read
    current_designer.seller_notifications.unread.update_all(read_at: Time.current)
    # 303: the documented Turbo contract for successful non-GET submissions.
    redirect_to designer_notifications_path, status: :see_other
  end
end
