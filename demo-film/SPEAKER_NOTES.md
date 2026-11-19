# Earshot demo film: speaker notes

The film runs 1:38 with text, sound effects and a quiet ambient bed, so your voice carries it. It sits after the problem slides and replaces the live demo. Each beat shows the pain as a small label and the feature as the big words. The lines are short on purpose: say them over the picture and let the hits land.

## Before you press play
- Play it with sound on and check the room speakers once. The music is low and deep, so on laptop speakers you will mostly hear the clicks and taps.
- Start talking at 0:02, when the clip appears.
- The two big moments are 0:38 (35%) and 1:30 (One call. Every chart.). Finish your sentence just before each one and let it land in silence.
- Stop talking at 1:33. The last five seconds are the logo and the tagline.

## Cue table
| Time | Pain label on screen | Big words and what is in focus | Say |
|---|---|---|---|
| 0:00 | none | A red light pulses, then the clip. "One clip." then "One button." | "This is the clip. The medic asks the patient, then presses it." |
| 0:07 | Hands stay on the patient | The three presses: click, double-click, hold | "One button: click to mark, double-click to pause, hold to start or end the call. Hands stay on the patient." |
| 0:10 | No setup on scene | The clip docks into the app. "Paired." in green, then "Ready" | "It pairs over Bluetooth with the iPad the crew already carries. When it says Ready, they go." |
| 0:20 | Nobody charts mid-call | Live transcript typing. "Every word, as it is said. On the iPad." | "From the first word, the call is written down live, on the iPad." |
| 0:30 | Numbers get lost in the noise | Four vitals chips lift out: BP 158/94, HR 104, RR 20, SpO2 95% | "It pulls the vitals out of the conversation, with the time they were said." |
| 0:34 | Stock speech AI mangles medicine | "Medic said: pulse oximetry. Stock Whisper: pulse on some tree. Earshot: pulse oximetry." Held for four seconds | "The medic says pulse oximetry. Stock Whisper hears 'pulse on some tree'. Ours gets it." |
| 0:38 | none | A giant red 35%, "fewer errors than stock Whisper", held to 0:42 | "Our model is tuned on EMS speech: 35 percent fewer errors on medical speech it had never heard." |
| 0:42 | Times get charted from memory | Clip on the left, the record on the right. A click sends a yellow dot across and "Mark 1" lands at 0:44, "Mark 2" at 0:48 | "Mid-treatment, the medic clicks the clip. That drops a mark in the record. It tells the AI what matters, at the second it happened." |
| 0:52 | Treatment times get audited | "Treatment by time": 02:05 Aspirin 324 mg, 02:05 Nitroglycerin 0.4 mg. "Every treatment, timed." | "So every treatment lands in the chart with its time. Those are the times that get audited." |
| 0:56 | The chart used to wait until after shift | The timer stops at 01:21. "81 seconds of audio." then Complete and "To sign" | "Call over. Eighty-one seconds of audio, and the report is already waiting." |
| 1:00 | The nurse gets 30 seconds | The handoff rows light up one by one. "Handoff, drafted." | "The nurse handoff: patient, latest vitals, what was given." |
| 1:03 | A chart is a legal record | Zoom on "Allergies: not heard". "Not heard? Left blank." | "Allergies never came up, so it leaves the line blank and flags it. The medic fills it in. The AI never guesses." |
| 1:08 | No signal. No cloud. | Narrative format switches from Plain to SOAP. "Written on this iPad." | "The narrative, in the format the agency uses, written on the iPad. No signal needed." |
| 1:12 | The medic stays accountable | The signature is drawn. "Nothing is final until they sign." | "Nothing is final until the medic signs." |
| 1:20 | none | 02:04 to 02:11 in green, "All signed" | "Call at 2:04. Signed at 2:11." |
| 1:22 | No retyping. No copy and paste. | "Straight to the ePCR." The ePCR panel turns green, then four documents lock in: Nurse handoff, PCR narrative, SOAP / CHART / DRAATT, NEMSIS 3.5.1 | "Once it is signed, Earshot connects directly to the agency's ePCR. Handoff, narrative, SOAP, NEMSIS: no retyping, no copy and paste." |
| 1:30 | Signed. Sent straight to your ePCR | The screen floods off-white. "One call. Every chart." then "Earshot. The EMS partner who never forgets." | "One call. Every chart. Earshot." Then stop talking. |

## If a judge asks
- **Where does 35% come from?** It is the deck's figure, measured on held-out clips of medical speech the model never trained on. My own re-run on 370 such clips showed the tuned model making about half the errors of stock Whisper (9.1 against 18.6 words wrong per 100), so 35% is on the safe side.
- **Does that hold on real radio audio?** Say it is not yet measured at scale. One three-minute spot check on real EMS radio reports put the tuned model level with stock Whisper, so keep the 35% claim to medical speech.
- **Does your pipeline add accuracy on top of the model?** The measured gain comes from the tuned model. The pipeline's job is timing, marks and the report.
- **Is the ePCR connection live?** The recorded app build exports with Copy PCR. The pipeline branch already writes a NEMSIS 3.5.1 chart and has a command that submits it to a NEMSIS v3 web service, which I saw and did not run. Present the direct connection as where the product is going.
- **Consent?** The film does not show it. Your line at 0:02 covers it: the medic asks the patient, then presses the clip.

## Where your footage goes (the bright blue areas in the EMT-slots cut)
| Slot | Time | Length | Frame | Shot |
|---|---|---|---|---|
| 1 | 0:02 to 0:10 | 8.0 s | Full frame, 1920 x 1080 | The clip on a collar or radio strap. The EMT presses it: once at 0:07, twice at 0:07.5, then holds at 0:08. Tight on chest and hands. |
| 2 | 0:42 to 0:52 | 9.9 s | Left panel only, upright, 735 x 1080 | Mid-treatment, the EMT taps the clip without looking down: taps at 0:44 and 0:48, which is when the marks land on the right. |
| 3 | 1:14 to 1:19 | 4.9 s | Full frame, 1920 x 1080 | The medic signs on the iPad, or turns it to the nurse. |

The big words stay on top of each slot, so the footage sits underneath them. Leave the lower-left of slot 1, the bottom half of slot 2 and the right half of slot 3 uncluttered.
