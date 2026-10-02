# EWA Deploy Parameters — قيم النشر الافتراضية

> كل القيم أدناه لها مصدر موثق. القيم من الاختبارات = سلوك مُختبر. القيم "بتوجيه صريح" = أمر المؤسس.
> **غيّر أي قيمة هنا** — ثم أعد توليد مقاطع النشر (أو أبلغ المنسق).
> تاريخ التثبيت: 2026-10-02. الشبكة: Base mainnet (8453).
> EWA_Core: `0x0201981D7BFE0E79DEACb0B5eae0F83022Cc18eB` | المؤسس: `0xE9B0CebeF9e93cAc7727A06D5ED5f8e3AE71e5F8`

## Batch1 — الأساس

| العقد | البرامتر | القيمة | المصدر | غيّرها هنا |
|---|---|---|---|---|
| EVA_Multisig | owners / threshold | [المؤسس] / 1 | سابقة المؤسس (1-of-1) | `batch1-ewa.sh` سطر MULTISIG_ARGS |
| EVA_Treasury | council | عنوان الـMultisig من نفس الدفعة | يُلتقط عند النشر | — |
| EVA_BoundedGovernance | council_ | [المؤسس] | سابقة المؤسس | `batch1-ewa.sh` سطر GOVERNANCE_ARGS |
| EVA_NFT | baseURI_ / minter_ | `""` / المؤسس | بتوجيه صريح: baseURI قرار branding للمؤسس | `batch1-ewa.sh` سطر NFT_ARGS |
| EVA_KeeperScheduler | registrar / cooldown | المؤسس / 86400 (يوم) | سابقة / افتراضي المنسق | `batch1-ewa.sh` |

**إصلاحات 2026-10-02:** BoundedGovernance أُضيف لها `abstract GovernedModule` (يرث IGovernedModule بحارس onlyGovernance) — أي عقد EWA يرث بسطر واحد. NFT أُضيف لها `setBaseURI` (للمينتر فقط)، الافتراضي `""` آمن ومتعمد.

## Batch2 — الموصولة بالكور

| العقد | البرامتر | القيمة | المصدر | غيّرها هنا |
|---|---|---|---|---|
| EVA_BoostAuction | epochLen / k / multBps / minBid | 86400 / 3 / 15000 (1.5x) / 1 EWA | test/suite/EVA_BoostAuction.t.sol:61 | `batch2-ewa.sh` سطر BOOST_ARGS |
| EVA_CongestionExit | baseBps / k / capBps / window / minLock / maxLock | 200 (2%) / 4e18 / 2500 (25%) / 7d / 30d / 365d | test/suite/EVA_CongestionExit.t.sol:55-63 | `batch2-ewa.sh` سطر CONGEXIT_ARGS |
| EVA_LoyaltyBadge | minter / tierMinimums / baseURI | المؤسس / [1k, 10k, 100k, 1M] EWA token-days / `""` | Tiers: test/suite/EVA_LoyaltyBadge.t.sol:40؛ بتوجيه صريح: minter=المؤسس، baseURI قرار branding | `batch2-ewa.sh` سطر BADGE_ARGS |
| EVA_Splitter | payees / shares | [المؤسس] / [10000] = 100% | بتوجيه صريح (موثق كقابل للتغيير) | `batch2-ewa.sh` سطر SPLITTER_ARGS |
| EVAFounderVesting | totalA / cliffA / durationA / totalB / durationB | 2M / 1yr / 3yr / 500k / 1yr | جدول EVA الأصلي **كمثال موثق** — الجدول النهائي قرار المؤسس | `batch2-ewa.sh` سطر FVEST_ARGS |
| EVA_LockVault | token | EWA_Core | — | — |
| EVA_RewardDistributor | token / epoch | EWA_Core / 86400 | — | — |

**تحذير:** موّل RewardDistributor عبر `fund()` فقط — التحويل المباشر يصبح رصيدًا غير محسوب (مؤكد).

**إصلاحات 2026-10-02:** FounderVesting أصبح جدولها صريحًا عبر الـconstructor (كانت مشفرة 2M/3yr/1yr-cliff + 500k/1yr) — نفس المنطق، بلا قيم مخفية.

## Batch3 — الدفاع

| العقد | البرامتر | القيمة | المصدر | غيّرها هنا |
|---|---|---|---|---|
| EVA_FeeAdaptationV2 | tiers / signalMaxAge | $0.01/$1/$100/$1000 (USD8) / 1d | سلم EVO v3 الدقيق | `batch3-ewa.sh` سطر FEEV2_ARGS |
| EVA_DangerScore | hub / weights[12] | EngineHub (نفس الدفعة) / 100k × 12 | أوزان محايدة placeholder — **قرار النمذجة النهائي للمؤسس** | `batch3-ewa.sh` سطر DANGER_ARGS |
| TWAPOracleEngine | feed | ETH/USD `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` | فيد Chainlink متحقق | — |
| AdaptiveDefense | registry | IncidentRegistry (batch1) | يُلتقط عند النشر | — |

**إصلاحات 2026-10-02:** FeeAdaptationV2 — فُرض `omega <= 10000` بالكود (`_omegaFactor`: أي omega خارج المقياس يُعامل كمفقود → عامل محايد x1.0؛ لا clamp ولا revert). DangerScore — تحقق شامل: الكود سليم بلا تغيير؛ 5 مفاتيح لها ناشرون أحياء، 3 مفاتيح (VOL/DEPTH/SOLVENCY) بلا ناشر في خطة EWA → تتدهور لـ"مفقود" (موثق ومقبول).

## Batch4 — التحكيم

| العقد | البرامتر | القيمة | المصدر | غيّرها هنا |
|---|---|---|---|---|
| EVA_VerifyJury | registry / window / minVoters / maxVoters / whaleCapBps / reporterBps / minStake | IncidentRegistry(batch1) / 3d / 3 / 50 / 2000 / 500 / 1 EWA | test/suite/EVA_VerifyJury.t.sol:70-79 (الـregistry كان mock في الاختبارات — الحقيقي من batch1) | `batch4-ewa.sh` سطر VERIFYJURY_ARGS |
| EVA_ThreatMarket | jury / juryStakeBp | VerifyJury (نفس الدفعة — **الترتيب إلزامي**) / 20000 (2x) | test/suite/EVA_ThreatMarket.t.sol:74 | `batch4-ewa.sh` سطر THREAT_ARGS |

## ما زال محجوبًا (قرارات المؤسس)

| العقد | ما ينقصه |
|---|---|
| EVA_OracleBlend | فيدا Chainlink حقيقيان إضافيان + staleness |
| EVA_USDThresholds | priceFeed حقيقي + confidenceSource + registrar + الأسماء/الأهداف |
| EVA_SortitionPanel | **مستبعد بقرار المؤسس** — لا VRF نهائيًا (2026-10-02) |

## ملاحظات الثقة

- كل سكريبت يرفض العمل حتى `export CONFIRM_DEFAULTS=yes` بعد مراجعة القيم المطبوعة أعلاه.
- كل عقد يتحقق بعد النشر أن عنوان التوكن/الـhub المخزن يساوي المتوقع بالحرف — أي mismatch يُسقط الدفعة.
- لا شيء نُشر على mainnet — التوقيع بيد المؤسس من Termux.
