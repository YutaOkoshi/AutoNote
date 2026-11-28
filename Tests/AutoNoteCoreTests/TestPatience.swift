/// How long a test waits for something that has to happen before it gives up.
///
/// Not a measure of speed. On the CI runner (3 cores) a parallel run stops every test for 20–40 s at a stretch while
/// the others use the threads, so a limit of a few seconds fails tests whose subject is fine. A test's verdict comes
/// from what happened, in which order and how often; this limit only ends a wait that would never end.
let testPatience: Duration = .seconds(120)
