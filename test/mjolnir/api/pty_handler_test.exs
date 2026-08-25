defmodule Mjolnir.API.PtyHandlerTest do
  use ExUnit.Case, async: true

  alias Mjolnir.API.PtyHandler

  test "ws_ping pushes a ping frame and reschedules" do
    state = %PtyHandler{vm_id: "vm", channel: 1, conn_pid: self()}
    assert {:push, {:ping, <<>>}, ^state} = PtyHandler.handle_info(:ws_ping, state)
  end
end
