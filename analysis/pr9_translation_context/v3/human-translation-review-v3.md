# VideoText PR #9: Human Translation Review V3

**Human review: NOT PERFORMED. No row is self-approved.**

Russian ASR is not audio-Gold. Listen to the source intervals when judging ambiguous rows.
All times below are relative to the 180-second clip (original recording: add 10 minutes).
The clip was recreated from the unchanged source recording; Whisper was not rerun.
Architecture: DOCUMENT CONTEXT + LOCAL OVERLAP CONTEXT + OWNED CONTENT.
Stable identity: cueId. Translation uses only translategemma:4b.
Protocol: `translategemma-booktext-owned-cues-v4-docmeta512-lineage2-overlap2x600-id-array-grammar2-ctx8k`.
Model digest: `c49d986b0764f5881c476eb21435bb62b7abc62347aab3d4a6071e811be510a1`.
Context identity: `022950cbaabd0d755af89cf4f85a8b683a7fd1afd66d7da182a7e081c2084b59`.
Structural issues: 0.
Automated failure-class alarms: 17-unsupported-completion.
These alarms are bounded fixture checks, not independent semantic acceptance.
[Source clip](/Users/yurielokhin/Documents/videotext-pr9-human-review-v3/source-10m-13m.mp4)

Release E2Es: DEFERRED. Candidate: NOT BUILT. Installed app: UNCHANGED.

## ID 1: 00:00:00.160 - 00:00:01.340

**Russian ASR**

1: Окей, чуть позже спрошу.

**Surrounding Russian source**

1: Окей, чуть позже спрошу.
2: Ирина Адамович.
3: Я есть. Здравствуйте.

**Original V1**

1: Okay, I'll ask later.

**Rejected V2 experiment**

1: Okay, I'll ask later.

**New production V3**

1: Okay, I'll ask later.

**Technical note**

Changed vs V1: NONE

## ID 2: 00:00:01.860 - 00:00:03.060

**Russian ASR**

2: Ирина Адамович.

**Surrounding Russian source**

1: Окей, чуть позже спрошу.
2: Ирина Адамович.
3: Я есть. Здравствуйте.
4: Здравствуйте. Готова. Спасибо.

**Original V1**

2: Irina Adamovich.

**Rejected V2 experiment**

2: Irina Adamovich.

**New production V3**

2: Irina Adamovich.

**Technical note**

Changed vs V1: NONE
Name spelling requires source-audio verification.

## ID 4: 00:00:12.910 - 00:00:24.100

**Russian ASR**

4: Здравствуйте. Готова. Спасибо.

**Surrounding Russian source**

2: Ирина Адамович.
3: Я есть. Здравствуйте.
4: Здравствуйте. Готова. Спасибо.
5: Любовь Зуева.
6: Здравствуйте. Я есть.

**Original V1**

4: Hello. I'm ready. Thank you.

**Rejected V2 experiment**

4: Hello. I am ready. Thank you.

**New production V3**

4: Hello. Ready. Thank you.

**Technical note**

Changed vs V1: 4

## ID 6: 00:00:28.520 - 00:00:31.830

**Russian ASR**

6: Здравствуйте. Я есть.

**Surrounding Russian source**

4: Здравствуйте. Готова. Спасибо.
5: Любовь Зуева.
6: Здравствуйте. Я есть.
7: Здравствуйте. Готова. Спасибо.
8: Маргарита Мирошиченко.

**Original V1**

6: Hello. I am here.

**Rejected V2 experiment**

6: Hello. I am here.

**New production V3**

6: Hello. I'm here.

**Technical note**

Changed vs V1: 6

## ID 8: 00:00:43.060 - 00:00:44.160

**Russian ASR**

8: Маргарита Мирошиченко.

**Surrounding Russian source**

6: Здравствуйте. Я есть.
7: Здравствуйте. Готова. Спасибо.
8: Маргарита Мирошиченко.
9: Добрый день. Я есть.
10: Готова. Спасибо.

**Original V1**

8: Margarita Miroshchenko.

**Rejected V2 experiment**

8: Маргарита Мирошиченко.

**New production V3**

8: Margarita Miroshchenko.

**Technical note**

Changed vs V1: NONE
Name spelling requires source-audio verification.

## ID 11: 00:00:59.300 - 00:01:02.070

**Russian ASR**

11: Марина Кушнарева.

**Surrounding Russian source**

9: Добрый день. Я есть.
10: Готова. Спасибо.
11: Марина Кушнарева.
12: Добрый вечер. Я есть.
13: Татьяна.

**Original V1**

11: Marina Kushnareva.

**Rejected V2 experiment**

11: Marina Kushnareva.

**New production V3**

11: Marina Kushnareva.

**Technical note**

Changed vs V1: NONE
Name spelling requires source-audio verification.

## ID 16: 00:01:38.760 - 00:01:40.000

**Russian ASR**

16: Так, сейчас у нас заочники.

**Surrounding Russian source**

14: Я есть.
15: Готова.
16: Так, сейчас у нас заочники.
17: Юрий, а я еще.
18: А, да, Светлана.

**Original V1**

16: Okay, so right now we have distance learners.

**Rejected V2 experiment**

16: Okay, so now we have distance learners.

**New production V3**

16: So, we have distance learners now.

**Technical note**

Changed vs V1: 16

## ID 17: 00:01:42.990 - 00:01:44.170

**Russian ASR**

17: Юрий, а я еще.

**Surrounding Russian source**

15: Готова.
16: Так, сейчас у нас заочники.
17: Юрий, а я еще.
18: А, да, Светлана.
19: Здравствуйте. Я есть.

**Original V1**

17: Yuri, and I am still.

**Rejected V2 experiment**

17: Yuri, and I'm still here.

**New production V3**

17: Yuri, and I'm still here.

**Technical note**

Changed vs V1: 17
Automated alarm: 17-unsupported-completion
Source cue is elliptical; the next cue is not an explicit completion. Listen and do not infer omitted speech.

## ID 21 / 22: 00:01:50.120 - 00:01:54.060

**Russian ASR**

21: Меня что-то выбрасывает сегодня.
22: Прям каждую минуту вообще ужас.

**Surrounding Russian source**

19: Здравствуйте. Я есть.
20: Здравствуйте.
21: Меня что-то выбрасывает сегодня.
22: Прям каждую минуту вообще ужас.
23: Ну, готова.
24: Теперь точно заочники, да?

**Original V1**

21: I seem to be having some stomach issues today.
22: It's absolutely terrifying every minute.

**Rejected V2 experiment**

21: Something is making me disconnect today.
22: It's absolutely terrifying every minute.

**New production V3**

21: Something keeps disconnecting me today.
22: It's just awful every minute.

**Technical note**

Changed vs V1: 21, 22

## ID 23: 00:01:56.250 - 00:02:18.730

**Russian ASR**

23: Ну, готова.

**Surrounding Russian source**

21: Меня что-то выбрасывает сегодня.
22: Прям каждую минуту вообще ужас.
23: Ну, готова.
24: Теперь точно заочники, да?

**Original V1**

23: Okay, I'm ready.

**Rejected V2 experiment**

23: Okay, now we have part-time students.

**New production V3**

23: Well, I'm ready.

**Technical note**

Changed vs V1: 23
The long source interval is an existing ASR-timeline anomaly, outside this translation change.

## ID 24: 00:02:22.500 - 00:02:24.240

**Russian ASR**

24: Теперь точно заочники, да?

**Surrounding Russian source**

22: Прям каждую минуту вообще ужас.
23: Ну, готова.
24: Теперь точно заочники, да?

**Original V1**

24: Now, definitely, are they?

**Rejected V2 experiment**

24: Now definitely part-time students, right?

**New production V3**

24: Now definitely distance learners, right?

**Technical note**

Changed vs V1: 24

## ID 19 / 20: 00:01:46.780 - 00:01:49.030

**Russian ASR**

19: Здравствуйте. Я есть.
20: Здравствуйте.

**Surrounding Russian source**

17: Юрий, а я еще.
18: А, да, Светлана.
19: Здравствуйте. Я есть.
20: Здравствуйте.
21: Меня что-то выбрасывает сегодня.
22: Прям каждую минуту вообще ужас.

**Original V1**

19: Hello. I am here.
20: Hello.

**Rejected V2 experiment**

19: Hello. I'm here.
20: Hello.

**New production V3**

19: Hello. I'm here.
20: Hello.

**Technical note**

Changed vs V1: 19

## All 24 production cues

- 1 | 00:00:00.160 - 00:00:01.340 | Okay, I'll ask later.
- 2 | 00:00:01.860 - 00:00:03.060 | Irina Adamovich.
- 3 | 00:00:10.760 - 00:00:12.490 | I'm here. Hello.
- 4 | 00:00:12.910 - 00:00:24.100 | Hello. Ready. Thank you.
- 5 | 00:00:25.590 - 00:00:26.850 | Lyubov Zueva.
- 6 | 00:00:28.520 - 00:00:31.830 | Hello. I'm here.
- 7 | 00:00:32.280 - 00:00:42.550 | Hello. Ready. Thank you.
- 8 | 00:00:43.060 - 00:00:44.160 | Margarita Miroshchenko.
- 9 | 00:00:46.050 - 00:00:47.370 | Good afternoon. I'm here.
- 10 | 00:00:53.290 - 00:00:58.100 | Ready. Thank you.
- 11 | 00:00:59.300 - 00:01:02.070 | Marina Kushnareva.
- 12 | 00:01:03.800 - 00:01:06.430 | Good evening. I'm here.
- 13 | 00:01:16.950 - 00:01:21.820 | Tatiana.
- 14 | 00:01:24.770 - 00:01:28.040 | I'm here.
- 15 | 00:01:37.860 - 00:01:38.340 | Ready.
- 16 | 00:01:38.760 - 00:01:40.000 | So, we have distance learners now.
- 17 | 00:01:42.990 - 00:01:44.170 | Yuri, and I'm still here.
- 18 | 00:01:45.070 - 00:01:45.920 | Oh, yes, Svetlana.
- 19 | 00:01:46.780 - 00:01:48.160 | Hello. I'm here.
- 20 | 00:01:48.160 - 00:01:49.030 | Hello.
- 21 | 00:01:50.120 - 00:01:52.300 | Something keeps disconnecting me today.
- 22 | 00:01:52.440 - 00:01:54.060 | It's just awful every minute.
- 23 | 00:01:56.250 - 00:02:18.730 | Well, I'm ready.
- 24 | 00:02:22.500 - 00:02:24.240 | Now definitely distance learners, right?
