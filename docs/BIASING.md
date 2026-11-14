# Biasing Whisper toward EMS vocabulary

Status, what was measured, what the research says, and the plan. Everything here is non-learned:
no model is trained or fine-tuned.

## What is built

- `core/Sources/EarshotCore/Hybrid/BiasTrie.swift`: drug names as Whisper token sequences. While
  Whisper decodes, `WhisperTranscriber` adds a logit bonus through whisper.cpp's
  `logits_filter_callback`: `bias_first` (0.5) for the first token of a name, `bias_next` (2.0) for
  a token that continues one already started.
- `EMSDictionary.biasPhrases()`: every generic, brand, alias and slang name of 4+ letters in
  `shared/formulary.json`, lower-case and capitalized. **367 words, 734 phrases.**
- `ConfidenceFlags`: a drug, dose or vital whose own tokens fall below probability 0.3 is "please confirm".
- `earshot-eval` options: `--no-bias`, `--bias-first`, `--bias-next`, `--min-conf`, `--gpu`.

## What was measured

10 test calls from the data team (regenerated audio locked to their ground truth, see
`eval/README.md`), 10 dB SNR, Whisper `small.en` (the same stock model as the data team's report),
their scorer.

| | No bias | Bias 0.5 / 2.0 |
|---|---|---|
| Word error rate | 48.8% | 35.8% |
| Drug-name error rate | 42.3% | 34.6% |
| Drug precision / recall | 0.94 / 0.77 | 0.95 / 0.82 |
| Dose recall | 0.73 | 0.77 |
| Prompt copies | 75 | 4 |

How to read it:

- **One clear fix from biasing:** "ipratropium" (was "iperfirpium").
- **Most of the drop is not biasing.** Without bias, Whisper fell into repeat loops on two calls
  ("Mhm" x40, "3.4 t 3.4 t ...", "For more information visit www..."); with bias it happened not to.
  Any change to the logits moves the beam search, so that part is chance. Hallucination is the
  largest error source in these runs and needs its own fix (see the plan).
- **Not fixed:** "Narcan" -> "Marcann" / "Marquin". Whisper goes wrong on the first token, which only
  gets the small bonus.
- **No false drugs:** precision held, so biasing did not make Whisper hear drugs that were not said.
- **Small sample:** the 10 calls have 26 spoken drug names.
- **Confidence flags:** only measurable for false alarms here (2 across the 10 calls at 0.3), because
  no extracted value in this set was wrong: every extraction error is a missed value.

## What the research says

1. **The list is too big.** Biasing studies consistently find that accuracy on words outside the
   list falls as the list grows past ~100 entries, while the gain on listed words shrinks. Ours has
   367 words. A practitioner report puts the trouble point for Whisper at about 50 terms. Fix: a short
   list ranked by how often each term is actually said in EMS calls, not every name in the formulary.
2. **Give the first token a real bonus, and take it back if the word is not finished.** Standard
   shallow-fusion biasing uses a "subtractive cost": the bonus paid while following a name is
   subtracted again if decoding leaves the name half way. That makes a larger first-token bonus safe,
   which is what "Narcan" needs. A logits hook can do this: it sees the tokens so far, so when the
   path is part-way into a name and the next token does not continue it, it can lower every other
   token by the bonus already paid.
3. **Bias by context, not one global list.** Production systems switch lists per situation. For us:
   a small always-on core (the most common drugs and terms) plus a per-call list from the dispatch
   type (chest pain: aspirin, nitro; overdose: Narcan; seizure: Versed, Ativan, Keppra).
4. **Several spellings per word.** The trie-biasing paper builds each hotword from several
   pronunciations/spellings so the bonus fires whichever way Whisper starts the word. Our
   misspelling list (`asr_variants`) is not used for biasing on purpose (it would teach the error),
   but it shows which first tokens Whisper actually picks ("Mar..." for Narcan).
5. **Mine the dictionary from real data.** Build the list from term frequencies in real EMS
   transcripts; learn Whisper's real confusions by aligning its output with correct transcripts and
   counting substitutions (keep pairs above a frequency threshold, check for homophones). With text
   only, the confusions can be generated: render sentences with TTS + noise, run Whisper, align. The
   data team already has a script in this style (`data/dictionary/mine_asr_variants_tts.py` in
   earshot-data).
6. **Prompt and biasing are complementary.** The initial prompt is short and global; our current
   format-only prompt was copied 75 times in one baseline run. Measure prompt off, prompt on, and
   bias, separately.
7. **Report two numbers.** B-WER (error on the listed words) and U-WER (error on all other words).
   A bias that helps B-WER but hurts U-WER is a trade, not a win. Also count false insertions on
   speech with no drugs.

## Plan (local, with the EMS transcript set)

1. **Mine the transcript set:** count every formulary term and EMS abbreviation; rank them; record
   which co-occur with which dispatch types. Output: a ranked core list (~50-100) and per-dispatch
   lists, committed to `shared/`.
2. **Subtractive cost in `BiasTrie`:** remember the bonus paid along the current partial match and
   subtract it from tokens that leave the name. Unit-test, then raise `bias_first`.
3. **Per-call lists:** the core list always; add the dispatch list once a dispatch reason is heard.
4. **Confusions:** TTS + noise over transcript sentences, Whisper, align, count; add frequent
   confusions to `asr_variants` (cleanup) and use the first tokens they reveal to check the trie.
5. **Measure with B-WER, U-WER and false insertions**, on the regenerated test calls plus a held-out
   slice of the transcript set rendered the same way, at 15/10/5 dB.
6. **Hallucination guard** (separate, rule-based): drop repeat loops, web-address and "subscribe"
   lines, and use whisper.cpp's no-speech probability.

## Sources

- [Zero-shot Context Biasing with Trie-based Decoding using Synthetic Multi-Pronunciation (arXiv 2508.17796)](https://arxiv.org/html/2508.17796)
- [Contextual Biasing without fine-tuning Whisper (arXiv 2410.18363)](https://arxiv.org/pdf/2410.18363)
- [CB-Whisper: keyword-spotting biasing](https://www.researchgate.net/publication/401317766_CB-Whisper_Contextual_Biasing_Whisper_Using_Open-Vocabulary_Keyword-Spotting)
- [Keyword-aware cost function (which subword tokens to bias)](https://pith.science/paper/2509.09197)
- [Practitioner report on large Whisper vocabularies](https://github.com/thijsdaniels/decktation/issues/2)
- [Contextual phrase prediction: list size 100 vs 1000 (arXiv 2305.12493)](https://arxiv.org/pdf/2305.12493)
- [Trie-based deep biasing and shallow fusion, distractor sizes (arXiv 2104.02194)](https://arxiv.org/pdf/2104.02194)
- [Biasing score learning and filtering (arXiv 2510.23849)](https://arxiv.org/pdf/2510.23849)
- [Speech LLM biasing, U-WER at 500 entries (arXiv 2604.00610)](https://arxiv.org/pdf/2604.00610)
- [Shallow fusion with subtractive cost (USPTO 11545142)](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/11545142)
- [Aho-Corasick keyword biasing, failure transitions (arXiv 2409.13514)](https://arxiv.org/html/2409.13514v2)
- [Boosting token extensions without an FST (arXiv 2310.00178)](https://arxiv.org/pdf/2310.00178v1.pdf)
- [Class LM and word mapping for contextual biasing (arXiv 2007.05609)](https://www.alphaxiv.org/abs/2007.05609.md)
- [Biasing list construction and distractors (overview)](https://www.emergentmind.com/topics/context-biasing-methods)
- [Common word cues and first-syllable phoneme retrieval (arXiv 2604.12398)](https://arxiv.org/html/2604.12398v1)
- [ASR error modelling from aligned transcripts (arXiv 1612.08375)](https://arxiv.org/pdf/1612.08375)
- [Learning from past mistakes: noisy-clean phrase context](https://www.cambridge.org/core/services/aop-cambridge-core/content/view/0025A4B2DF4F33B90FB090A195D304ED/S2048770318000318a.pdf/learning-from-past-mistakes-improving-automatic-speech-recognition-output-via-noisy-clean-phrase-context-modeling.pdf)
- [Named-entity correction and homophones (arXiv 2403.17645)](https://arxiv.org/pdf/2403.17645.pdf)
- [Medical terminology gaps in Whisper (TUM thesis)](https://www.cs.cit.tum.de/fileadmin/w00cfj/sebis/_my_direct_uploads/Leonhard_Siegfried_Stengel_Abschlussarbeit.pdf)
