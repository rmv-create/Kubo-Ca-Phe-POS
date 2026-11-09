/// Who is at the till right now, for the activity trail.
///
/// The audit log has had an `actor` column since the day staff PINs were
/// added, and nothing ever wrote to it: every entry said what happened and
/// none said who did it. In a shop where two people share a till, "who
/// voided the ₱169" is the whole question.
///
/// A function rather than a value because the services are built once and
/// the person at the till changes through the day.
typedef WhoIsWorking = String? Function();

/// Nobody signed in — a shop that has not set up its PINs yet, or a test.
String? nobody() => null;
