# frozen_string_literal: true

require "system_helper"

# Issue #365: js.show_modal / js.close_dialog and data-reactive-modal. The
# browser does the modal part (top layer, focus trap, Escape, focus restored
# to the opener); these examples prove the library gets every dialog there —
# from a client op, at connect, after a morph reply and after a replace reply
# — and back out again when a morph renders it closed.
RSpec.describe "Modal dialogs (issue #365)", type: :system do
  def modal?(testid)
    page.evaluate_script("document.querySelector('[data-testid=#{testid}]').matches(':modal')")
  end

  def focused_testid
    page.evaluate_script("document.activeElement?.dataset?.testid ?? null")
  end

  # Where focus lands after each of `times` presses of `key`.
  def focus_places_after(key, testid, times: 6)
    Array.new(times) do
      page.driver.with_playwright_page { it.keyboard.press(key) }
      focus_place(testid)
    end
  end

  # Where focus is relative to the dialog: "inside", "outside" (a page element
  # behind the modal), or "chrome" — a modal dialog lets Tab leave for the
  # browser's own UI, which reads as document.body from the page.
  def focus_place(testid)
    page.evaluate_script(<<~JS)
      document.activeElement === document.body ? "chrome" :
        (document.activeElement?.closest("[data-testid=#{testid}]") ? "inside" : "outside")
    JS
  end

  context "with the client ops" do
    before { visit "/modal_dialog" }

    it "opens the picker as a modal and closes it with close_dialog" do
      find("[data-testid='choose']").click
      expect(page).to have_css("[data-testid='picker'][open]")
      expect(modal?("picker")).to be(true)

      find("[data-testid='picker-close']").click
      expect(page).to have_no_css("[data-testid='picker'][open]", visible: :all)
      expect(modal?("picker")).to be(false)
    end

    it "keeps Tab and Shift+Tab inside the dialog" do
      find("[data-testid='choose']").click
      expect(page).to have_css("[data-testid='picker'][open]")

      # Never on the page behind the modal, and back inside after every wrap.
      %w[Tab Shift+Tab].each do
        places = focus_places_after(it, "picker")
        expect(places).not_to include("outside")
        expect(places.count("inside")).to be >= 3
      end
    end

    it "closes on Escape and returns focus to the opener" do
      find("[data-testid='choose']").click
      expect(page).to have_css("[data-testid='picker'][open]")
      find("[data-testid='picker-search']").click

      page.driver.with_playwright_page { it.keyboard.press("Escape") }

      expect(page).to have_no_css("[data-testid='picker'][open]", visible: :all)
      expect(focused_testid).to eq("choose")
    end
  end

  context "with data-reactive-modal" do
    it "makes a dialog rendered open on the page modal at connect" do
      visit "/modal_dialog?open=1"

      expect(page).to have_css("[data-testid='server-dialog'][open]")
      expect(modal?("server-dialog")).to be(true)
    end

    it "makes a dialog a morph reply renders open modal" do
      visit "/modal_dialog"
      find("[data-testid='open-morph']").click

      expect(page).to have_css("[data-testid='server-dialog'][open]")
      expect(modal?("server-dialog")).to be(true)
    end

    it "makes a dialog a replace reply renders open modal" do
      visit "/modal_dialog"
      find("[data-testid='open-replace']").click

      expect(page).to have_css("[data-testid='server-dialog'][open]")
      expect(modal?("server-dialog")).to be(true)
    end

    it "keeps the dialog modal when a morph renders it open again" do
      visit "/modal_dialog"
      find("[data-testid='open-morph']").click
      expect(page).to have_css("[data-testid='server-dialog'][open]")

      find("[data-testid='refresh-morph']").click

      expect(page).to have_css("[data-testid='refreshes']", text: "Refreshed 1")
      expect(page).to have_css("[data-testid='server-dialog'][open]")
      expect(modal?("server-dialog")).to be(true)
    end

    it "closes the modal when a morph renders it closed, and the page takes clicks again" do
      visit "/modal_dialog"
      find("[data-testid='open-morph']").click
      expect(page).to have_css("[data-testid='server-dialog'][open]")

      find("[data-testid='close-morph']").click

      expect(page).to have_no_css("[data-testid='server-dialog'][open]", visible: :all)
      expect(modal?("server-dialog")).to be(false)
      find("[data-testid='behind']").click
      expect(page).to have_css("[data-testid='behind-clicks']", text: "clicked")
    end

    it "leaves no modal behind when a replace reply renders it closed" do
      visit "/modal_dialog"
      find("[data-testid='open-morph']").click
      expect(page).to have_css("[data-testid='server-dialog'][open]")

      find("[data-testid='close-replace']").click

      expect(page).to have_no_css("[data-testid='server-dialog'][open]", visible: :all)
      expect(page.evaluate_script("document.querySelectorAll(':modal').length")).to eq(0)
      find("[data-testid='behind']").click
      expect(page).to have_css("[data-testid='behind-clicks']", text: "clicked")
    end
  end
end
