defmodule SyncordianWeb.ReadmeLog do
  @moduledoc """
  LiveView that displays the test git log used to drive experiments (route `/readmelog`).

  Reads the Oh My Zsh README commit-history fixture from
  `test/git_log/ohmyzsh_README_full_git_log` and renders it, so you can see the
  sequence of commits whose insert/delete edits are replayed against the peers.
  """
  use SyncordianWeb, :live_view

  def mount(_params, _session, socket) do
    readme_content = fetch_readme_content()
    {:ok, assign(socket, readme_content: readme_content)}
  end

  defp fetch_readme_content do
    readme_path = "test/git_log/ohmyzsh_README_full_git_log"

    case File.read(readme_path) do
      {:ok, content} -> content
      {:error, reason} -> "Failed to read README file: #{reason}"
    end
  end
end
