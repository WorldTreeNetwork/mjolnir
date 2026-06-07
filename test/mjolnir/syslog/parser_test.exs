defmodule Mjolnir.Syslog.ParserTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Syslog.Parser
  alias Mjolnir.Syslog.Message

  describe "parse/1 — well-formed RFC 3164 messages" do
    test "parses message with tag and pid" do
      line = "<134>Jun  6 12:34:56 vm-abc ci[1234]: + npm install"
      assert {:ok, %Message{} = msg} = Parser.parse(line)

      # facility 134 div 8 = 16 = :local0, severity 134 rem 8 = 6 = :info
      assert msg.facility == :local0
      assert msg.severity == :info
      assert msg.hostname == "vm-abc"
      assert msg.tag == "ci"
      assert msg.pid == 1234
      assert msg.message == "+ npm install"
      assert msg.raw == line
      assert %NaiveDateTime{month: 6, day: 6, hour: 12, minute: 34, second: 56} = msg.timestamp
    end

    test "parses message with tag but no pid" do
      line = "<13>Jan  1 00:00:00 myhost kernel: some kernel message"
      assert {:ok, %Message{} = msg} = Parser.parse(line)

      # facility 13 div 8 = 1 = :user, severity 13 rem 8 = 5 = :notice
      assert msg.facility == :user
      assert msg.severity == :notice
      assert msg.hostname == "myhost"
      assert msg.tag == "kernel"
      assert msg.pid == nil
      assert msg.message == "some kernel message"
    end

    test "parses busybox syslogd format with space-padded day" do
      line = "<165>Aug 24 05:34:00 mymachine myproc[10]: %% It's time to make the do-nuts."
      assert {:ok, %Message{} = msg} = Parser.parse(line)

      # facility 165 div 8 = 20 = :local4, severity 165 rem 8 = 5 = :notice
      assert msg.facility == :local4
      assert msg.severity == :notice
      assert msg.hostname == "mymachine"
      assert msg.tag == "myproc"
      assert msg.pid == 10
      assert msg.message == "%% It's time to make the do-nuts."
    end

    test "parses all severity values" do
      severities = [
        {0, :emergency},
        {1, :alert},
        {2, :critical},
        {3, :error},
        {4, :warning},
        {5, :notice},
        {6, :info},
        {7, :debug}
      ]

      for {sev_num, sev_atom} <- severities do
        # facility 0 (kern), varying severity
        pri = sev_num
        line = "<#{pri}>Jun  6 12:00:00 host tag: msg"
        assert {:ok, msg} = Parser.parse(line)
        assert msg.severity == sev_atom, "expected #{sev_atom} for priority #{pri}"
        assert msg.facility == :kern
      end
    end

    test "parses all local facilities" do
      facilities = [
        {16, :local0},
        {17, :local1},
        {18, :local2},
        {19, :local3},
        {20, :local4},
        {21, :local5},
        {22, :local6},
        {23, :local7}
      ]

      for {fac_num, fac_atom} <- facilities do
        # severity 6 (info)
        pri = fac_num * 8 + 6
        line = "<#{pri}>Jun  6 12:00:00 host tag: msg"
        assert {:ok, msg} = Parser.parse(line)
        assert msg.facility == fac_atom, "expected #{fac_atom} for priority #{pri}"
      end
    end

    test "parses common facility atoms" do
      cases = [
        {0, :kern},
        {1, :user},
        {2, :mail},
        {3, :daemon},
        {4, :auth},
        {5, :syslog}
      ]

      for {fac_num, fac_atom} <- cases do
        pri = fac_num * 8 + 6
        line = "<#{pri}>Jun  6 12:00:00 host tag: msg"
        assert {:ok, msg} = Parser.parse(line)
        assert msg.facility == fac_atom
      end
    end

    test "raw field always set to input line" do
      line = "<134>Jun  6 12:34:56 vm-abc ci[1234]: message here"
      assert {:ok, msg} = Parser.parse(line)
      assert msg.raw == line
    end

    test "strips trailing newline from raw" do
      line = "<134>Jun  6 12:34:56 vm-abc ci[1234]: message\n"
      assert {:ok, msg} = Parser.parse(line)
      assert msg.raw == String.trim_trailing(line, "\n")
    end

    test "parses message with colon in content" do
      line = "<134>Jun  6 12:34:56 host sshd[999]: Accepted publickey for root from 1.2.3.4 port 22 ssh2: RSA SHA256:abc"
      assert {:ok, msg} = Parser.parse(line)
      assert msg.tag == "sshd"
      assert msg.pid == 999
      assert String.contains?(msg.message, "RSA SHA256:abc")
    end

    test "parses single-digit day (space-padded)" do
      line = "<134>Jun  6 12:34:56 host tag: msg"
      assert {:ok, msg} = Parser.parse(line)
      assert msg.timestamp.day == 6
    end
  end

  describe "parse/1 — malformed messages" do
    test "returns error tuple for message without priority" do
      line = "Jun  6 12:34:56 host tag: msg"
      assert {:error, :malformed, %Message{raw: ^line}} = Parser.parse(line)
    end

    test "returns error tuple for empty string" do
      assert {:error, :malformed, %Message{raw: ""}} = Parser.parse("")
    end

    test "returns error tuple for priority-only message" do
      line = "<134>"
      assert {:error, :malformed, %Message{}} = Parser.parse(line)
    end

    test "returns facility and severity even for malformed header" do
      line = "<134>NOTADATE host tag: msg"
      result = Parser.parse(line)
      # Priority is valid so facility/severity should be set, header parse fails
      assert {:error, :malformed, msg} = result
      assert msg.facility == :local0
      assert msg.severity == :info
    end

    test "returns error for invalid priority value" do
      line = "<999>Jun  6 12:34:56 host tag: msg"
      assert {:error, :malformed, %Message{}} = Parser.parse(line)
    end

    test "handles message with no tag gracefully" do
      # Some syslog implementations emit bare messages
      line = "<134>Jun  6 12:34:56 host just a bare message"
      # This may parse partially — just ensure no crash
      result = Parser.parse(line)
      assert match?({:ok, _}, result) or match?({:error, :malformed, _}, result)
    end
  end

  describe "priority decoding" do
    test "priority 0 is kern/emergency" do
      assert {:ok, msg} = Parser.parse("<0>Jun  6 12:00:00 h t: m")
      assert msg.facility == :kern
      assert msg.severity == :emergency
    end

    test "priority 191 is local7/debug (max valid)" do
      # 23 * 8 + 7 = 191
      assert {:ok, msg} = Parser.parse("<191>Jun  6 12:00:00 h t: m")
      assert msg.facility == :local7
      assert msg.severity == :debug
    end
  end
end
