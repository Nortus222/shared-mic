using System.Runtime.CompilerServices;

// Test-only visibility for internal members that exist purely to let the
// test suite assert on implementation state (e.g. pending signal counts)
// without widening the public API surface.
[assembly: InternalsVisibleTo("SharedMic.Agent.Tests")]
