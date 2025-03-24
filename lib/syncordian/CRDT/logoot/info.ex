defmodule Syncordian.CRDT.Logoot.Info do
  alias Syncordian.CRDT.Logoot.Sequence

  @spec save_tree_content(Sequence.t(), Syncordian.Basic_Types.peer_id()) :: :ok
  def save_tree_content(sequence, peer_id) do
    file_path = "debug/documents/logoot/"

    # Ensure the directory exists
    unless File.dir?(file_path) do
      File.mkdir_p!(file_path)
    end

    # Write the file
    File.write!(file_path <> "document_#{peer_id}", sequence_to_string(sequence))
  end

  @spec sequence_to_string(Sequence.t()) :: String.t()
  def sequence_to_string(sequence) do
    sequence
    |> Sequence.get_values()
    |> Enum.join("\n")        # Join all strings with a newline
  end
end
