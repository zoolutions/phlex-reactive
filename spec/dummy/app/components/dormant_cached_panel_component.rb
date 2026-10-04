# frozen_string_literal: true

# Issues #274 + #276 + #277: a dormant, event-triggered, cacheable panel. The
# shell is dormant (no controller until `panel:opened`), the event wakes the
# root and GETs the cacheable fragment, and that fragment — fetched by a client
# that is by then loaded — renders AWAKE, so the replaced root needs no second
# wake (and the cached copy is the awake one).
class DormantCachedPanelComponent < CachedPanelComponent
  reactive_dormant

  def id = "dormant-cached-panel"
end
