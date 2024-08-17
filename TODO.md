# Pending or Important task

Check list to track the progress and current working on

## Woking on

- Currently I modify the parse of commits to count in each insertion/deletion within the
index of the Syncordian edit. Additionally a new parameter was added to such edits,
the global_position, it is used to search tombstones from the beginning of the document
until that index.

- Theory: I think that the insertion must be dynamic, if we are adding a line in the last
part of the document we must pick [i,i+1] else [i-1,i] in the function get_parents_by_index


## Pending

    - [x] Send the confirmation message to the sender when inserte a new incoming
    message.
    - [ ] TODO: When calculating the distance between the clocks, need the case when the
    value is less than or equal to 0, this is probably due to an interiving solved case.
    - [ ] TODO: When adding a new line to the document change update the commit_at list?
    in the receving peer?

    - [ ] TODO: revie the distance, it is possible to be distance 0, we are comparing the
    receving projection howcome that we have a message from the recing peer that has 0
    as a distance that means that we have all the information from that peer.

## Ideas

    - Using the sucsefully inserted message we can update receiving peer clock??
