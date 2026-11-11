# Long dictation in TextEdit

Measure on the same Mac with the same locally synthesized audio file, output and input devices, model, language, and TextEdit document setup for both builds. Warm the installed model before playback. Start with an empty disposable plain-text document and play the fixture over the speakers into the microphone. Use a fixture long enough to cross multiple decode boundaries.

Record the monotonic time at the stop signal and after Accessibility confirms the text change. Compare that interval across baseline and candidate runs. Read back the inserted text and compare it to the known synthetic reference. Report deletions, insertions, substitutions, and repeated adjacent words or phrases. Mark an unconfirmed insertion as a failed run.

A candidate must reduce the median stop-to-confirmed-insertion time and introduce no additional word errors or repetitions on the fixed fixture. Keep individual run counts and timings alongside the median. The test uses local models and synthetic material.
