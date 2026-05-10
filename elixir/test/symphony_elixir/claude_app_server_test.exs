defmodule SymphonyElixir.Claude.AppServerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.AppServer

  describe "stream_event_from_line/1" do
    test "parses known Claude stream-json event types without dynamic atoms" do
      {event, details} =
        AppServer.stream_event_from_line(~s({"type":"message_start","message":{"id":"msg_1"}}))

      assert event == :claude_message_start
      assert details.payload["message"]["id"] == "msg_1"
    end

    test "keeps unknown event types on a stable fallback atom" do
      {event, details} =
        AppServer.stream_event_from_line(~s({"type":"new_event_from_cli","value":1}))

      assert event == :claude_event
      assert details.payload["value"] == 1
    end

    test "forwards malformed lines as stream text" do
      assert {:stream_text, %{raw: "not-json"}} = AppServer.stream_event_from_line("not-json")
    end
  end
end
