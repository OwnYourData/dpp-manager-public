class SettingsController < ApplicationController
  def show
    @setting = settings
  end

  # Only what actually changed is logged, as the values the setting holds: the
  # form sends every field on every save, and a checkbox arrives as "1" or "0"
  # for a setting that is true or false.
  def update
    @setting = settings
    @setting.assign_attributes(permitted)
    changed = @setting.changes_to_save.slice(*permitted.keys)

    if @setting.save
      changed.each { |key, (from, to)| Event.record!(:setting_changed, setting: key, from: from, to: to) }
      redirect_to settings_path, notice: t("settings.saved")
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def permitted
    params.require(:setting).permit(:locale, :help_mode, :idle_timeout_minutes)
  end
end
