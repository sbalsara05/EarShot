#!/usr/bin/env python3
"""Build /shared/formulary.json and /shared/ems_terms.json.

Inputs
  * CURATED seed below: drug list, typical adult doses/routes and slang taken
    from the Massachusetts Statewide Treatment Protocols (v2024.1) and
    cross-checked against the NY-REMAC and Wake County EMS protocols
    (see /shared/SOURCES.md).
  * RxNorm REST API (rxnav.nlm.nih.gov): RXCUI, brand names (TTY=BN),
    synonyms.
  * openFDA drug label API (api.fda.gov): label routes (openfda.route).
  * NEMSIS v3.5.1 XSDs (nemsis.org): route + unit code lists.
    Pass --nemsis-dir pointing at a folder holding commonTypes_v3.xsd and
    eMedications_v3.xsd.

Network results are cached in --cache (JSON) so re-runs are deterministic
and offline. Run:
    python3 core/tools/build_dictionary.py --nemsis-dir /path/to/xsds \
        --cache core/tools/.dict_cache.json --out shared/
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from phonetic import phonetic_key  # noqa: E402

# ---------------------------------------------------------------------------
# Curated drug seed.
# key: generic (lower case). Fields:
#   cls: drug class (short), slang: what medics say, asr: misrecognitions we
#   have seen or expect from Whisper, doses: list of typical adult doses as
#   [amount, unit, route], routes: allowed routes (Earshot route codes),
#   high_alert: True for drugs where a wrong dose is dangerous (forces confirm)
# Route codes used across Earshot: PO SL IV IO IM IN SQ NEB INH ET PR TOP BUC TD
# ---------------------------------------------------------------------------
SEED = {
    "aspirin": dict(cls="antiplatelet", slang=["asa", "baby aspirin", "chewable aspirin"],
                    asr=["as burn", "asprin", "aspirin's", "a s a"],
                    doses=[["324", "mg", "PO"], ["325", "mg", "PO"], ["162", "mg", "PO"], ["81", "mg", "PO"]], routes=["PO"]),
    "nitroglycerin": dict(cls="vasodilator", slang=["nitro", "ntg", "nitro spray", "nitro tab", "nitro paste"],
                          asr=["nitro glycerin", "night row", "nitrogen", "nitro glycerine", "nitroglycerine"],
                          doses=[["0.4", "mg", "SL"]], routes=["SL", "TD", "IV"]),
    "epinephrine": dict(cls="sympathomimetic", slang=["epi", "adrenaline", "epi pen", "epipen", "push dose epi", "one milligram epi", "cardiac epi"],
                        asr=["epi nephrine", "epinephrin", "epi friend"],
                        doses=[["0.3", "mg", "IM"], ["0.5", "mg", "IM"], ["0.15", "mg", "IM"], ["1", "mg", "IV"], ["1", "mg", "IO"], ["10", "mcg", "IV"]],
                        routes=["IM", "IV", "IO", "NEB", "ET"], high_alert=True),
    "racemic epinephrine": dict(cls="sympathomimetic", slang=["racemic epi", "racepinephrine"], asr=["race emic epi"],
                                doses=[["0.5", "ml", "NEB"]], routes=["NEB"]),
    "naloxone": dict(cls="opioid antagonist", slang=["narcan", "nalox"], asr=["nar can", "narc an", "now locks own", "naloxon"],
                     doses=[["0.4", "mg", "IV"], ["2", "mg", "IN"], ["4", "mg", "IN"], ["0.4", "mg", "IM"], ["2", "mg", "IV"]],
                     routes=["IN", "IV", "IM", "IO", "SQ"]),
    "albuterol": dict(cls="bronchodilator", slang=["albuterol neb", "proventil", "ventolin", "breathing treatment"],
                      asr=["al butyrol", "albuterl", "all bureau", "albuterols"],
                      doses=[["2.5", "mg", "NEB"], ["5", "mg", "NEB"]], routes=["NEB", "INH"]),
    "ipratropium": dict(cls="anticholinergic bronchodilator", slang=["atrovent", "duoneb", "duo neb"],
                        asr=["ipra tropium", "a tro vent", "do a neb", "duo nab"],
                        doses=[["0.5", "mg", "NEB"]], routes=["NEB"]),
    "oral glucose": dict(cls="antihypoglycemic", slang=["glucose gel", "insta glucose", "glutose", "oral glucose gel", "sugar gel"],
                         asr=["glue cose", "glucose jell"], doses=[["15", "g", "PO"], ["24", "g", "PO"]], routes=["PO", "BUC"]),
    "dextrose": dict(cls="antihypoglycemic", slang=["d10", "d50", "d25", "dextrose 10", "dextrose 50", "amp of d50"],
                     asr=["d 10", "d 50", "dee ten", "dee fifty", "dex rose", "dextrose's"],
                     doses=[["25", "g", "IV"], ["12.5", "g", "IV"], ["250", "ml", "IV"], ["100", "ml", "IV"]], routes=["IV", "IO"], high_alert=True),
    "glucagon": dict(cls="antihypoglycemic", slang=["glucagen"], asr=["glue ca gone", "glucagons", "glucose gone"],
                     doses=[["1", "mg", "IM"], ["1", "mg", "IN"], ["3", "mg", "IN"]], routes=["IM", "IN", "IV", "SQ"]),
    "ondansetron": dict(cls="antiemetic", slang=["zofran", "zofran odt"], asr=["so fran", "zo fran", "zofren", "ondansetrin", "on dancetron"],
                        doses=[["4", "mg", "IV"], ["4", "mg", "PO"], ["8", "mg", "PO"], ["4", "mg", "IM"]], routes=["IV", "IM", "PO", "IO"]),
    "fentanyl": dict(cls="opioid analgesic", slang=["fent", "sublimaze"], asr=["fent and ill", "fentanil", "fenton al", "fentanyls", "fentanol"],
                     doses=[["50", "mcg", "IV"], ["25", "mcg", "IV"], ["100", "mcg", "IN"], ["1", "mcg/kg", "IV"]],
                     routes=["IV", "IN", "IM", "IO"], high_alert=True),
    "morphine": dict(cls="opioid analgesic", slang=["ms", "morphine sulfate", "mso4"], asr=["more feen", "morphene"],
                     doses=[["4", "mg", "IV"], ["2", "mg", "IV"], ["0.1", "mg/kg", "IV"]], routes=["IV", "IM", "IO"], high_alert=True),
    "hydromorphone": dict(cls="opioid analgesic", slang=["dilaudid"], asr=["dye lauded", "the laudid", "hydro morphone"],
                          doses=[["0.5", "mg", "IV"], ["1", "mg", "IV"]], routes=["IV", "IM"], high_alert=True),
    "ketamine": dict(cls="dissociative anesthetic", slang=["ketalar", "special k", "ket"], asr=["keta mean", "ketamin", "key to mean", "cat a mean"],
                     doses=[["0.3", "mg/kg", "IV"], ["4", "mg/kg", "IM"], ["50", "mg", "IV"], ["2", "mg/kg", "IV"]],
                     routes=["IV", "IM", "IN", "IO"], high_alert=True),
    "midazolam": dict(cls="benzodiazepine", slang=["versed"], asr=["mid as olam", "verse said", "versed's", "midazolan", "midazepam"],
                      doses=[["2.5", "mg", "IV"], ["5", "mg", "IM"], ["10", "mg", "IM"], ["5", "mg", "IN"]], routes=["IV", "IM", "IN", "IO"], high_alert=True),
    "diazepam": dict(cls="benzodiazepine", slang=["valium"], asr=["die as a pam", "valley um"],
                     doses=[["5", "mg", "IV"], ["10", "mg", "PR"]], routes=["IV", "PR", "IM", "IO"], high_alert=True),
    "lorazepam": dict(cls="benzodiazepine", slang=["ativan"], asr=["at a van", "adavan", "lorazapam"],
                      doses=[["2", "mg", "IV"], ["1", "mg", "IV"], ["4", "mg", "IV"]], routes=["IV", "IM", "IO"], high_alert=True),
    "diphenhydramine": dict(cls="antihistamine", slang=["benadryl"], asr=["bena drill", "ben a drill", "die fen hydra mean", "benedryl"],
                            doses=[["25", "mg", "IV"], ["50", "mg", "IV"], ["50", "mg", "IM"], ["50", "mg", "PO"]], routes=["IV", "IM", "PO", "IO"]),
    "methylprednisolone": dict(cls="corticosteroid", slang=["solu-medrol", "solumedrol", "solu medrol"], asr=["sole you med roll", "solu metrol", "method pred"],
                               doses=[["125", "mg", "IV"]], routes=["IV", "IM", "IO"]),
    "dexamethasone": dict(cls="corticosteroid", slang=["decadron", "dex"], asr=["dexa methasone", "deca drone"],
                          doses=[["10", "mg", "IV"], ["8", "mg", "IV"], ["10", "mg", "PO"]], routes=["IV", "IM", "PO", "IO"]),
    "magnesium sulfate": dict(cls="electrolyte", slang=["mag", "mag sulfate", "magnesium", "mgso4"], asr=["mag sulfite", "magnesium sulphate"],
                              doses=[["2", "g", "IV"], ["4", "g", "IV"]], routes=["IV", "IO"], high_alert=True),
    "amiodarone": dict(cls="antiarrhythmic", slang=["amio", "cordarone", "nexterone"], asr=["amy oh da rone", "ami adorn", "amiodaron", "amy oh"],
                       doses=[["300", "mg", "IV"], ["150", "mg", "IV"]], routes=["IV", "IO"], high_alert=True),
    "lidocaine": dict(cls="antiarrhythmic / local anesthetic", slang=["lido", "xylocaine"], asr=["lido cane", "lighter cane", "lidocane"],
                      doses=[["1.5", "mg/kg", "IV"], ["1", "mg/kg", "IV"], ["40", "mg", "IO"]], routes=["IV", "IO", "TOP"], high_alert=True),
    "adenosine": dict(cls="antiarrhythmic", slang=["adenocard"], asr=["a den o seen", "adenosene", "add no scene"],
                      doses=[["6", "mg", "IV"], ["12", "mg", "IV"]], routes=["IV", "IO"], high_alert=True),
    "atropine": dict(cls="anticholinergic", slang=["atropine sulfate"], asr=["at row peen", "atro pine", "a trophy"],
                     doses=[["1", "mg", "IV"], ["0.5", "mg", "IV"], ["2", "mg", "IM"]], routes=["IV", "IO", "IM"], high_alert=True),
    "diltiazem": dict(cls="calcium channel blocker", slang=["cardizem", "dilt"], asr=["dill tea a zem", "card is em", "diltiazam"],
                      doses=[["0.25", "mg/kg", "IV"], ["10", "mg", "IV"], ["20", "mg", "IV"]], routes=["IV"], high_alert=True),
    "metoprolol": dict(cls="beta blocker", slang=["lopressor"], asr=["meto pro lol", "low presser"], doses=[["5", "mg", "IV"]], routes=["IV", "PO"]),
    "calcium chloride": dict(cls="electrolyte", slang=["calcium", "cacl"], asr=["calcium chlorine"], doses=[["1", "g", "IV"]], routes=["IV", "IO"], high_alert=True),
    "calcium gluconate": dict(cls="electrolyte", slang=["calcium gluc"], asr=["calcium glue con ate"], doses=[["3", "g", "IV"], ["1", "g", "IV"]], routes=["IV", "IO"]),
    "sodium bicarbonate": dict(cls="alkalinizer", slang=["bicarb", "sodium bicarb", "bicarb amp"], asr=["by carb", "bi carb", "sodium bicarb nate"],
                               doses=[["50", "meq", "IV"], ["1", "meq/kg", "IV"]], routes=["IV", "IO"], high_alert=True),
    "normal saline": dict(cls="crystalloid", slang=["ns", "saline", "fluid bolus", "bolus", "0.9 saline", "sodium chloride"],
                          asr=["normal sailing", "in s", "saline bolus"], doses=[["500", "ml", "IV"], ["1000", "ml", "IV"], ["250", "ml", "IV"], ["20", "ml/kg", "IV"]],
                          routes=["IV", "IO"]),
    "lactated ringers": dict(cls="crystalloid", slang=["lr", "ringers", "lactated ringer's", "ringer's lactate"], asr=["lactated ringer", "l r", "lack tated ringers"],
                             doses=[["500", "ml", "IV"], ["1000", "ml", "IV"]], routes=["IV", "IO"]),
    "oxygen": dict(cls="gas", slang=["o2", "high flow", "high flow oxygen", "supplemental oxygen"],
                   asr=["oh two", "o two", "non re breather", "nasal canula"],
                   doses=[["2", "lpm", "NC"], ["4", "lpm", "NC"], ["15", "lpm", "NRB"], ["10", "lpm", "NRB"]], routes=["NC", "NRB", "BVM", "CPAP", "BLOWBY", "INH"]),
    "tranexamic acid": dict(cls="antifibrinolytic", slang=["txa", "cyklokapron"], asr=["t x a", "tea x a", "tranexamic"],
                            doses=[["1", "g", "IV"], ["2", "g", "IV"]], routes=["IV", "IO"]),
    "ketorolac": dict(cls="nsaid", slang=["toradol"], asr=["tore a dull", "tora doll", "keto rolac"], doses=[["15", "mg", "IV"], ["30", "mg", "IM"]], routes=["IV", "IM"]),
    "acetaminophen": dict(cls="analgesic / antipyretic", slang=["tylenol", "apap", "ofirmev", "paracetamol"], asr=["a seat a mino fen", "tile and all", "tylenols"],
                          doses=[["1000", "mg", "IV"], ["1000", "mg", "PO"], ["650", "mg", "PO"], ["15", "mg/kg", "PO"]], routes=["PO", "IV", "PR"]),
    "ibuprofen": dict(cls="nsaid", slang=["motrin", "advil"], asr=["eye bu pro fen", "i be profen"], doses=[["400", "mg", "PO"], ["600", "mg", "PO"], ["800", "mg", "PO"]], routes=["PO"]),
    "oxytocin": dict(cls="hormone", slang=["pitocin", "pit"], asr=["ox e toe sin", "pito sin"], doses=[["10", "units", "IM"], ["20", "units", "IV"]], routes=["IM", "IV"]),
    "norepinephrine": dict(cls="vasopressor", slang=["levophed", "levo", "norepi"], asr=["leave a fed", "nor epi", "levo fed"],
                           doses=[["2", "mcg/min", "IV"], ["8", "mcg/min", "IV"]], routes=["IV", "IO"], high_alert=True),
    "dopamine": dict(cls="vasopressor", slang=["intropin"], asr=["dope a mean", "dopa mean"], doses=[["5", "mcg/kg/min", "IV"], ["10", "mcg/kg/min", "IV"]], routes=["IV", "IO"], high_alert=True),
    "haloperidol": dict(cls="antipsychotic", slang=["haldol"], asr=["hal doll", "halo perry doll"], doses=[["5", "mg", "IM"], ["2.5", "mg", "IV"]], routes=["IM", "IV"]),
    "droperidol": dict(cls="antipsychotic", slang=["inapsine"], asr=["drop perry doll", "drop air a doll"], doses=[["2.5", "mg", "IV"], ["5", "mg", "IM"], ["10", "mg", "IM"]], routes=["IV", "IM"]),
    "olanzapine": dict(cls="antipsychotic", slang=["zyprexa"], asr=["oh lanza peen", "zy prexa"], doses=[["10", "mg", "IM"], ["10", "mg", "PO"]], routes=["IM", "PO"]),
    "prochlorperazine": dict(cls="antiemetic", slang=["compazine"], asr=["com pa zeen", "pro chlor perazine"], doses=[["10", "mg", "IV"], ["10", "mg", "IM"]], routes=["IV", "IM"]),
    "promethazine": dict(cls="antiemetic", slang=["phenergan"], asr=["fen er gan", "pro meth a zine"], doses=[["12.5", "mg", "IV"], ["25", "mg", "IM"]], routes=["IV", "IM"]),
    "famotidine": dict(cls="h2 blocker", slang=["pepcid"], asr=["fa mo ti dean", "pep sid"], doses=[["20", "mg", "IV"]], routes=["IV", "PO"]),
    "nitrous oxide": dict(cls="analgesic gas", slang=["nitronox", "laughing gas", "n2o"], asr=["nitrous", "nitro knox"], doses=[], routes=["INH"]),
    "activated charcoal": dict(cls="adsorbent", slang=["charcoal", "actidose"], asr=["activated char coal"], doses=[["50", "g", "PO"], ["1", "g/kg", "PO"]], routes=["PO"]),
    "hydroxocobalamin": dict(cls="antidote", slang=["cyanokit"], asr=["hydroxo cobalamin", "cyano kit"], doses=[["5", "g", "IV"]], routes=["IV", "IO"]),
    "atropine and pralidoxime": dict(cls="antidote", slang=["duodote", "mark 1 kit", "mark one kit", "2-pam"], asr=["duo dote", "mark one"], doses=[["1", "kit", "IM"]], routes=["IM"]),
    "etomidate": dict(cls="sedative / induction agent", slang=["amidate"], asr=["eto mid ate", "a toe mid ate"], doses=[["0.3", "mg/kg", "IV"], ["20", "mg", "IV"]], routes=["IV", "IO"], high_alert=True),
    "rocuronium": dict(cls="paralytic", slang=["roc", "zemuron"], asr=["rock you ronium", "rocky ronium"], doses=[["1", "mg/kg", "IV"], ["100", "mg", "IV"]], routes=["IV", "IO"], high_alert=True),
    "succinylcholine": dict(cls="paralytic", slang=["sux", "anectine", "succs"], asr=["sucks", "suck sinful colleen", "succinyl choline"], doses=[["1.5", "mg/kg", "IV"], ["100", "mg", "IV"]], routes=["IV", "IO"], high_alert=True),
    "vecuronium": dict(cls="paralytic", slang=["vec", "norcuron"], asr=["vec you ronium"], doses=[["0.1", "mg/kg", "IV"]], routes=["IV"], high_alert=True),
    "thiamine": dict(cls="vitamin", slang=["vitamin b1", "b1"], asr=["thigh a mean", "thiamin"], doses=[["100", "mg", "IV"]], routes=["IV", "IM"]),
    "labetalol": dict(cls="beta blocker", slang=["trandate"], asr=["la bet a lol", "label all"], doses=[["10", "mg", "IV"], ["20", "mg", "IV"]], routes=["IV"]),
    "terbutaline": dict(cls="bronchodilator", slang=["brethine"], asr=["terbu ta lean", "turbo ta lean"], doses=[["0.25", "mg", "SQ"]], routes=["SQ"]),
    "heparin": dict(cls="anticoagulant", slang=["hep"], asr=["hep a rin", "heparine"], doses=[["5000", "units", "IV"], ["60", "units/kg", "IV"]], routes=["IV"], high_alert=True),
    "ticagrelor": dict(cls="antiplatelet", slang=["brilinta"], asr=["tie ca grel or", "brilliant a"], doses=[["180", "mg", "PO"]], routes=["PO"]),
    "clopidogrel": dict(cls="antiplatelet", slang=["plavix"], asr=["clo pid o grel", "play vix"], doses=[["600", "mg", "PO"], ["300", "mg", "PO"]], routes=["PO"]),
    "levetiracetam": dict(cls="anticonvulsant", slang=["keppra"], asr=["kepra", "lev a tear a see tam"], doses=[["60", "mg/kg", "IV"], ["1000", "mg", "IV"]], routes=["IV"]),
    "nicardipine": dict(cls="calcium channel blocker", slang=["cardene"], asr=["nick are da peen"], doses=[["5", "mg/hr", "IV"]], routes=["IV"]),
    "hydralazine": dict(cls="vasodilator", slang=["apresoline"], asr=["hydra la zeen"], doses=[["10", "mg", "IV"]], routes=["IV", "IM"]),
    "nitroglycerin paste": dict(cls="vasodilator", slang=["nitro paste", "nitrobid"], asr=["nitro bid"], doses=[["1", "inch", "TD"]], routes=["TD"]),
    "cetirizine": dict(cls="antihistamine", slang=["zyrtec"], asr=["zer tech"], doses=[["10", "mg", "PO"]], routes=["PO"]),
    "phenylephrine": dict(cls="vasopressor", slang=["neo", "neosynephrine", "push dose neo"], asr=["fennel efrin"], doses=[["100", "mcg", "IV"]], routes=["IV"], high_alert=True),
    "vasopressin": dict(cls="vasopressor", slang=["vaso", "pitressin"], asr=["vaso pressin"], doses=[["40", "units", "IV"]], routes=["IV", "IO"], high_alert=True),
    "insulin": dict(cls="hormone", slang=["regular insulin", "humalog", "novolog", "lantus"], asr=["in sue lin"], doses=[], routes=["SQ", "IV"], high_alert=True),
    "glucose": dict(cls="antihypoglycemic", slang=["juice", "orange juice", "sugar"], asr=[], doses=[], routes=["PO"]),
    "proparacaine": dict(cls="topical anesthetic", slang=["alcaine", "tetracaine"], asr=["pro para cane"], doses=[["2", "drops", "TOP"]], routes=["TOP"]),
}

# Route vocabulary: Earshot code -> (spoken forms, NEMSIS eMedications.04 code)
ROUTES = {
    "PO": (["po", "by mouth", "oral", "orally", "chewed", "chew", "swallowed", "p o"], "9927035"),
    "SL": (["sl", "sublingual", "under the tongue", "sub lingual", "s l"], "9927047"),
    "IV": (["iv", "intravenous", "iv push", "ivp", "i v", "push", "pushed", "iv piggyback", "drip"], "9927023"),
    "IO": (["io", "intraosseous", "i o", "humeral io", "tibial io"], "9927021"),
    "IM": (["im", "intramuscular", "i m", "in the thigh", "in the deltoid", "lateral thigh"], "9927015"),
    "IN": (["in", "intranasal", "nasal", "atomized", "mad device", "up the nose", "per nose"], "9927017"),
    "SQ": (["sq", "subq", "sub q", "subcutaneous", "sc", "sub cut"], "9927045"),
    "NEB": (["neb", "nebulized", "nebulizer", "via neb", "hand held neb", "inline neb", "by nebulizer"], "9927071"),
    "NRB": (["non rebreather", "non-rebreather", "nrb", "via nrb", "via non rebreather", "now we're breather", "non rib breather", "nonrebreather"], "9927031"),
    "NC": (["nasal cannula", "nasal canula", "via nasal cannula", "via nc", "cannula"], "9927025"),
    "BVM": (["bvm", "bag valve mask", "via bvm"], "9927065"),
    "CPAP": (["cpap", "on cpap", "via cpap"], "9927067"),
    "BLOWBY": (["blow by", "blowby"], "9927001"),
    "INH": (["inhaled", "inhalation", "mdi", "inhaler"], "9927009"),
    "ET": (["et", "endotracheal", "down the tube"], "9927005"),
    "PR": (["pr", "rectal", "rectally"], "9927043"),
    "TOP": (["topical", "topically"], "9927049"),
    "BUC": (["buccal", "in the cheek", "between cheek and gum"], "9927003"),
    "TD": (["transdermal", "patch", "paste"], "9927053"),
}

# Unit vocabulary: canonical -> (spoken forms, NEMSIS eMedications.06 code)
UNITS = {
    "mg": (["mg", "milligram", "milligrams", "migs", "milligrams of", "mgs", "milli grams"], "3706021"),
    "mcg": (["mcg", "microgram", "micrograms", "mics", "mikes", "micro", "micrograms of", "ug"], "3706015"),
    "g": (["g", "gram", "grams", "gm", "gms"], "3706001"),
    "ml": (["ml", "milliliter", "milliliters", "cc", "ccs", "mls", "mil", "mils"], "3706025"),
    "l": (["l", "liter", "liters", "litre", "leader", "leaders"], "3706009"),
    "meq": (["meq", "milliequivalent", "milliequivalents", "mill equivalents"], "3706019"),
    "units": (["units", "unit", "u", "iu", "international units"], "3706049"),
    "lpm": (["lpm", "liters per minute", "liters a minute", "l per minute", "liters", "leaders"], "3706035"),
    "mg/kg": (["mg/kg", "milligrams per kilo", "milligrams per kilogram", "migs per kilo", "mg per kg"], "3706039"),
    "mcg/kg": (["mcg/kg", "micrograms per kilo", "mics per kilo", "micrograms per kilogram"], "3706047"),
    "mcg/min": (["mcg/min", "micrograms per minute", "mics a minute"], "3706037"),
    "mcg/kg/min": (["mcg/kg/min", "micrograms per kilo per minute"], "3706017"),
    "mg/hr": (["mg/hr", "milligrams per hour", "milligrams an hour"], "3706055"),
    "ml/kg": (["ml/kg", "mls per kilo", "cc per kilo", "ccs per kilo", "milliliters per kilogram"], "3706029"),
    "units/kg": (["units/kg", "units per kilo"], "3706053"),
    "meq/kg": (["meq/kg", "milliequivalents per kilo"], "3706029"),
    "g/kg": (["g/kg", "grams per kilo"], "3706029"),
    "drops": (["drops", "gtts", "drop"], "3706033"),
    "puffs": (["puffs", "puff", "sprays", "spray"], "3706043"),
    "inch": (["inch", "inches"], "3706003"),
    "kit": (["kit", "kits", "auto injector"], "3706029"),
}

# ---------------------------------------------------------------------------
# EMS terms: abbreviation/jargon -> expansion, category.
# Categories: vital, assessment, status, procedure, history, anatomy, radio,
#             transport, dispatch, time, equipment, med_admin, general
# ---------------------------------------------------------------------------
TERMS = [
    # vitals
    ("bp", "blood pressure", "vital"), ("hr", "heart rate", "vital"), ("pulse", "heart rate", "vital"),
    ("rr", "respiratory rate", "vital"), ("resps", "respirations", "vital"), ("respirations", "respiratory rate", "vital"),
    ("spo2", "oxygen saturation", "vital"), ("sat", "oxygen saturation", "vital"), ("sats", "oxygen saturation", "vital"),
    ("pulse ox", "pulse oximetry", "vital"), ("o2 sat", "oxygen saturation", "vital"),
    ("etco2", "end-tidal carbon dioxide", "vital"), ("end tidal", "end-tidal carbon dioxide", "vital"), ("capno", "capnography", "vital"),
    ("bgl", "blood glucose level", "vital"), ("cbg", "capillary blood glucose", "vital"), ("sugar", "blood glucose", "vital"),
    ("glucose", "blood glucose", "vital"), ("d stick", "blood glucose check", "vital"), ("dextro", "blood glucose check", "vital"),
    ("gcs", "Glasgow Coma Scale", "vital"), ("temp", "temperature", "vital"), ("map", "mean arterial pressure", "vital"),
    ("pain scale", "pain score 0-10", "vital"), ("pain score", "pain score 0-10", "vital"),
    ("orthostatics", "orthostatic vital signs", "vital"), ("vitals", "vital signs", "vital"), ("v s", "vital signs", "vital"),
    ("palp", "by palpation", "vital"), ("by palp", "by palpation", "vital"),
    # mental status / assessment
    ("a&o", "alert and oriented", "assessment"), ("a and o", "alert and oriented", "assessment"),
    ("aox4", "alert and oriented to person, place, time and event", "assessment"),
    ("a&ox4", "alert and oriented to person, place, time and event", "assessment"),
    ("a and o times four", "alert and oriented to person, place, time and event", "assessment"),
    ("a and o by four", "alert and oriented to person, place, time and event", "assessment"),
    ("a and o times three", "alert and oriented to person, place and time", "assessment"),
    ("avpu", "alert, verbal, pain, unresponsive", "assessment"),
    ("loc", "level of consciousness / loss of consciousness", "assessment"),
    ("perrl", "pupils equal, round, reactive to light", "assessment"),
    ("perrla", "pupils equal, round, reactive to light and accommodation", "assessment"),
    ("cms", "circulation, motor, sensation", "assessment"), ("pms", "pulse, motor, sensation", "assessment"),
    ("dcap-btls", "deformities, contusions, abrasions, punctures, burns, tenderness, lacerations, swelling", "assessment"),
    ("opqrst", "onset, provocation, quality, region/radiation, severity, time", "assessment"),
    ("sample", "signs/symptoms, allergies, medications, past history, last oral intake, events", "assessment"),
    ("jvd", "jugular venous distension", "assessment"), ("skin signs", "skin color, temperature, condition", "assessment"),
    ("pink warm dry", "normal skin signs", "assessment"), ("pwd", "pink, warm, dry skin", "assessment"),
    ("diaphoretic", "sweating profusely", "assessment"), ("cyanotic", "bluish skin color", "assessment"),
    ("pale cool clammy", "pale, cool, clammy skin", "assessment"), ("mottled", "blotchy skin discoloration", "assessment"),
    ("lung sounds", "breath sounds", "assessment"), ("clear bilaterally", "breath sounds clear on both sides", "assessment"),
    ("rales", "crackles in lungs", "assessment"), ("crackles", "crackles in lungs", "assessment"),
    ("rhonchi", "coarse lung sounds", "assessment"), ("wheezing", "wheezes", "assessment"), ("wheezes", "wheezes", "assessment"),
    ("stridor", "high-pitched upper airway sound", "assessment"), ("diminished", "decreased breath sounds", "assessment"),
    ("tripoding", "tripod positioning (respiratory distress)", "assessment"), ("accessory muscle use", "accessory muscle use", "assessment"),
    ("retractions", "chest wall retractions", "assessment"), ("cap refill", "capillary refill", "assessment"),
    ("facial droop", "facial droop", "assessment"), ("slurred speech", "slurred speech", "assessment"),
    ("arm drift", "arm drift", "assessment"), ("be fast", "balance, eyes, face, arms, speech, time stroke screen", "assessment"),
    ("cincinnati", "Cincinnati prehospital stroke scale", "assessment"), ("lams", "Los Angeles motor scale", "assessment"),
    ("race scale", "rapid arterial occlusion evaluation", "assessment"),
    ("lkw", "last known well", "assessment"), ("last known well", "last known well time", "assessment"),
    ("nsr", "normal sinus rhythm", "assessment"), ("sinus tach", "sinus tachycardia", "assessment"),
    ("sinus brady", "sinus bradycardia", "assessment"), ("afib", "atrial fibrillation", "assessment"),
    ("a fib", "atrial fibrillation", "assessment"), ("rvr", "rapid ventricular response", "assessment"),
    ("svt", "supraventricular tachycardia", "assessment"), ("vtach", "ventricular tachycardia", "assessment"),
    ("v tach", "ventricular tachycardia", "assessment"), ("vfib", "ventricular fibrillation", "assessment"),
    ("v fib", "ventricular fibrillation", "assessment"), ("pea", "pulseless electrical activity", "assessment"),
    ("asystole", "asystole", "assessment"), ("stemi", "ST-elevation myocardial infarction", "assessment"),
    ("st elevation", "ST-segment elevation", "assessment"), ("pvcs", "premature ventricular contractions", "assessment"),
    ("rosc", "return of spontaneous circulation", "status"),
    ("12 lead", "12-lead ECG", "procedure"), ("twelve lead", "12-lead ECG", "procedure"),
    ("ekg", "electrocardiogram", "procedure"), ("ecg", "electrocardiogram", "procedure"),
    ("sob", "shortness of breath", "assessment"), ("dib", "difficulty in breathing", "assessment"),
    ("doe", "dyspnea on exertion", "assessment"), ("cp", "chest pain", "assessment"),
    ("n/v", "nausea/vomiting", "assessment"), ("n v", "nausea/vomiting", "assessment"), ("ams", "altered mental status", "assessment"),
    ("syncope", "fainting", "assessment"), ("near syncope", "near fainting", "assessment"),
    ("etoh", "alcohol", "assessment"), ("loc negative", "no loss of consciousness", "assessment"),
    ("nad", "no acute distress", "assessment"), ("wnl", "within normal limits", "assessment"),
    ("unremarkable", "no abnormal findings", "assessment"),
    # status words (shorthand medics use for patient condition / trend)
    ("compensating", "compensated shock: maintaining perfusion via compensatory mechanisms", "status"),
    ("decompensating", "failing compensatory mechanisms; worsening perfusion", "status"),
    ("crashing", "rapidly deteriorating", "status"), ("circling the drain", "rapidly deteriorating", "status"),
    ("stable", "condition stable", "status"), ("unstable", "condition unstable", "status"),
    ("improving", "condition improving", "status"), ("worsening", "condition worsening", "status"),
    ("deteriorating", "condition worsening", "status"), ("no change", "condition unchanged", "status"),
    ("unchanged", "condition unchanged", "status"), ("guarded", "guarded condition", "status"),
    ("altered", "altered mental status", "status"), ("unresponsive", "unresponsive", "status"),
    ("responsive", "responsive", "status"), ("combative", "combative", "status"), ("agitated", "agitated", "status"),
    ("in arrest", "cardiac arrest", "status"), ("coding", "in cardiac arrest", "status"), ("code", "cardiac arrest", "status"),
    ("pulses back", "return of spontaneous circulation", "status"), ("lost pulses", "loss of pulses", "status"),
    ("apneic", "not breathing", "status"), ("posturing", "abnormal posturing", "status"), ("seizing", "actively seizing", "status"),
    ("postictal", "post-seizure state", "status"), ("hypotensive", "low blood pressure", "status"),
    ("hypertensive", "high blood pressure", "status"), ("tachy", "tachycardic", "status"), ("brady", "bradycardic", "status"),
    ("hypoxic", "low oxygen", "status"), ("hypoglycemic", "low blood sugar", "status"),
    ("load and go", "rapid transport", "status"), ("priority one", "highest priority", "status"),
    # procedures
    ("iv access", "intravenous access", "procedure"), ("iv established", "intravenous access established", "procedure"),
    ("18 gauge", "18-gauge IV catheter", "procedure"), ("20 gauge", "20-gauge IV catheter", "procedure"),
    ("22 gauge", "22-gauge IV catheter", "procedure"), ("16 gauge", "16-gauge IV catheter", "procedure"),
    ("ac", "antecubital", "anatomy"), ("left ac", "left antecubital", "anatomy"), ("right ac", "right antecubital", "anatomy"),
    ("io access", "intraosseous access", "procedure"), ("ez io", "EZ-IO intraosseous device", "procedure"),
    ("cpr", "cardiopulmonary resuscitation", "procedure"), ("compressions", "chest compressions", "procedure"),
    ("aed", "automated external defibrillator", "equipment"), ("shocked", "defibrillation delivered", "procedure"),
    ("shock", "defibrillation", "procedure"), ("defib", "defibrillation", "procedure"),
    ("cardioversion", "synchronized cardioversion", "procedure"), ("cardioverted", "synchronized cardioversion delivered", "procedure"),
    ("pacing", "transcutaneous pacing", "procedure"), ("tcp", "transcutaneous pacing", "procedure"),
    ("intubated", "endotracheal intubation", "procedure"), ("intubation", "endotracheal intubation", "procedure"),
    ("tubed", "endotracheal intubation", "procedure"), ("ett", "endotracheal tube", "equipment"),
    ("igel", "i-gel supraglottic airway", "procedure"), ("i gel", "i-gel supraglottic airway", "procedure"),
    ("king airway", "King LT supraglottic airway", "procedure"), ("sga", "supraglottic airway", "procedure"),
    ("opa", "oropharyngeal airway", "procedure"), ("npa", "nasopharyngeal airway", "procedure"),
    ("bvm", "bag-valve-mask ventilation", "procedure"), ("bagging", "bag-valve-mask ventilation", "procedure"),
    ("cpap", "continuous positive airway pressure", "procedure"), ("suction", "airway suctioning", "procedure"),
    ("suctioned", "airway suctioned", "procedure"), ("needle decompression", "needle chest decompression", "procedure"),
    ("needle d", "needle chest decompression", "procedure"), ("c collar", "cervical collar", "procedure"),
    ("c-collar", "cervical collar", "procedure"), ("collared", "cervical collar applied", "procedure"),
    ("smr", "spinal motion restriction", "procedure"), ("backboard", "long spine board", "equipment"),
    ("tourniquet", "tourniquet applied", "procedure"), ("tq", "tourniquet", "procedure"),
    ("splint", "splint applied", "procedure"), ("splinted", "splint applied", "procedure"),
    ("traction splint", "traction splint", "procedure"), ("pelvic binder", "pelvic binder", "procedure"),
    ("wound packing", "wound packing", "procedure"), ("pressure dressing", "pressure dressing", "procedure"),
    ("bleeding control", "hemorrhage control", "procedure"), ("cold pack", "cold pack applied", "procedure"),
    ("o2 applied", "oxygen applied", "procedure"), ("nrb", "non-rebreather mask", "equipment"),
    ("nc", "nasal cannula", "equipment"), ("lucas", "LUCAS mechanical CPR device", "equipment"),
    ("lifepak", "LIFEPAK monitor/defibrillator", "equipment"), ("zoll", "Zoll monitor/defibrillator", "equipment"),
    ("monitor", "cardiac monitor", "equipment"), ("pads on", "defibrillation pads applied", "procedure"),
    ("stair chair", "stair chair", "equipment"), ("stretcher", "stretcher", "equipment"), ("cot", "stretcher", "equipment"),
    # history
    ("pmh", "past medical history", "history"), ("hx", "history", "history"), ("pmhx", "past medical history", "history"),
    ("nkda", "no known drug allergies", "history"), ("nka", "no known allergies", "history"),
    ("meds", "medications", "history"), ("chf", "congestive heart failure", "history"),
    ("copd", "chronic obstructive pulmonary disease", "history"), ("htn", "hypertension", "history"),
    ("dm", "diabetes mellitus", "history"), ("iddm", "insulin-dependent diabetes", "history"),
    ("niddm", "non-insulin-dependent diabetes", "history"), ("cad", "coronary artery disease", "history"),
    ("mi", "myocardial infarction", "history"), ("cva", "stroke (cerebrovascular accident)", "history"),
    ("tia", "transient ischemic attack", "history"), ("esrd", "end-stage renal disease", "history"),
    ("dnr", "do not resuscitate", "history"), ("molst", "medical orders for life-sustaining treatment", "history"),
    ("polst", "physician orders for life-sustaining treatment", "history"), ("blood thinners", "anticoagulants", "history"),
    ("last oral intake", "last oral intake", "history"), ("lmp", "last menstrual period", "history"),
    ("g p", "gravida/para", "history"),
    # anatomy / mechanism
    ("ruq", "right upper quadrant", "anatomy"), ("luq", "left upper quadrant", "anatomy"),
    ("rlq", "right lower quadrant", "anatomy"), ("llq", "left lower quadrant", "anatomy"),
    ("loc head strike", "head strike with loss of consciousness", "general"), ("moi", "mechanism of injury", "general"),
    ("noi", "nature of illness", "general"), ("mva", "motor vehicle accident", "dispatch"), ("mvc", "motor vehicle collision", "dispatch"),
    ("ground level fall", "fall from standing", "dispatch"), ("glf", "ground level fall", "dispatch"),
    ("cc", "chief complaint", "general"), ("chief complaint", "chief complaint", "general"),
    ("pt", "patient", "general"), ("y o", "year old", "general"), ("yo", "year old", "general"),
    ("yom", "year-old male", "general"), ("yof", "year-old female", "general"), ("prn", "as needed", "general"),
    ("abc", "airway, breathing, circulation", "assessment"), ("xabc", "exsanguination, airway, breathing, circulation", "assessment"),
    ("march", "massive hemorrhage, airway, respiration, circulation, hypothermia", "assessment"),
    # dispatch / radio
    ("dispatched for", "dispatched for", "dispatch"), ("call came in as", "dispatched for", "dispatch"),
    ("turned out to be", "found to be", "dispatch"), ("on scene", "arrived on scene", "time"),
    ("en route", "en route", "time"), ("responding", "responding", "time"), ("10-4", "acknowledged", "radio"),
    ("copy", "acknowledged", "radio"), ("eta", "estimated time of arrival", "transport"),
    ("medcom", "medical communications / hospital notification", "radio"), ("patch", "radio patch to hospital", "radio"),
    ("medical control", "online medical control", "radio"), ("olmc", "online medical control", "radio"),
    ("als", "advanced life support", "general"), ("bls", "basic life support", "general"),
    ("intercept", "ALS intercept", "transport"), ("mutual aid", "mutual aid", "dispatch"),
    ("priority 1", "emergent response", "dispatch"), ("hot", "lights and sirens", "transport"),
    ("cold", "no lights and sirens", "transport"), ("code 3", "lights and sirens", "transport"),
    ("lights and sirens", "lights and sirens", "transport"),
    # transport
    ("transporting", "transport initiated", "transport"), ("transport to", "transport to destination", "transport"),
    ("headed to", "transport to destination", "transport"), ("en route to", "transport to destination", "transport"),
    ("ed", "emergency department", "transport"), ("er", "emergency room", "transport"),
    ("trauma center", "trauma center", "transport"), ("cath lab", "cardiac catheterization lab", "transport"),
    ("stroke center", "stroke center", "transport"), ("stemi alert", "STEMI alert to receiving hospital", "transport"),
    ("stroke alert", "stroke alert to receiving hospital", "transport"), ("trauma alert", "trauma alert", "transport"),
    ("refusal", "patient refusal of care/transport", "transport"), ("ama", "against medical advice", "transport"),
    ("wall time", "time waiting at ED before transfer of care", "time"), ("offload", "transfer of patient to ED bed", "time"),
    ("triage", "ED triage", "transport"), ("bedside", "transfer at ED bedside", "transport"),
    ("transfer of care", "transfer of care to ED staff", "time"), ("report given", "verbal report to nurse", "time"),
    # symptoms (documented as heard; Earshot never turns these into a diagnosis)
    ("chest pain", "chest pain", "symptom"), ("chest pressure", "chest pressure", "symptom"), ("chest tightness", "chest tightness", "symptom"),
    ("shortness of breath", "shortness of breath", "symptom"), ("short of breath", "shortness of breath", "symptom"),
    ("difficulty breathing", "difficulty breathing", "symptom"), ("trouble breathing", "difficulty breathing", "symptom"),
    ("can't breathe", "difficulty breathing", "symptom"), ("nausea", "nausea", "symptom"), ("nauseous", "nausea", "symptom"),
    ("vomiting", "vomiting", "symptom"), ("threw up", "vomiting", "symptom"), ("dizzy", "dizziness", "symptom"),
    ("dizziness", "dizziness", "symptom"), ("lightheaded", "lightheadedness", "symptom"), ("headache", "headache", "symptom"),
    ("abdominal pain", "abdominal pain", "symptom"), ("belly pain", "abdominal pain", "symptom"), ("stomach pain", "abdominal pain", "symptom"),
    ("back pain", "back pain", "symptom"), ("neck pain", "neck pain", "symptom"), ("weakness", "weakness", "symptom"),
    ("numbness", "numbness", "symptom"), ("tingling", "tingling", "symptom"), ("palpitations", "palpitations", "symptom"),
    ("fever", "fever", "symptom"), ("chills", "chills", "symptom"), ("passed out", "syncope (reported)", "symptom"),
    ("fainted", "syncope (reported)", "symptom"), ("blacked out", "syncope (reported)", "symptom"), ("seizure", "seizure", "symptom"),
    ("bleeding", "bleeding", "symptom"), ("confusion", "confusion", "symptom"), ("confused", "confusion", "symptom"),
    ("radiating", "radiating pain", "symptom"), ("radiates", "radiating pain", "symptom"), ("jaw pain", "jaw pain", "symptom"),
    ("arm pain", "arm pain", "symptom"), ("hip pain", "hip pain", "symptom"), ("leg pain", "leg pain", "symptom"),
    ("swelling", "swelling", "symptom"), ("itching", "itching", "symptom"), ("hives", "hives", "symptom"), ("rash", "rash", "symptom"),
    ("throat tightness", "throat tightness", "symptom"), ("blurred vision", "blurred vision", "symptom"),
    ("anxious", "anxiety", "symptom"), ("sweaty", "diaphoresis", "symptom"), ("cough", "cough", "symptom"),
    # med admin words
    ("administered", "administered", "med_admin"), ("gave", "administered", "med_admin"), ("given", "administered", "med_admin"),
    ("pushed", "IV push given", "med_admin"), ("hung", "IV fluid started", "med_admin"), ("spiked", "IV bag prepared", "med_admin"),
    ("repeat", "repeat dose", "med_admin"), ("second dose", "repeat dose", "med_admin"), ("titrate", "titrate to effect", "med_admin"),
    ("kvo", "keep vein open", "med_admin"), ("tko", "to keep open", "med_admin"), ("wide open", "fluids at maximum rate", "med_admin"),
    ("bolus", "fluid bolus", "med_admin"), ("amp", "ampule", "med_admin"),
]

# Base initial-prompt (Whisper is primed with these words most).
PROMPT_CORE = [
    "BP", "heart rate", "SpO2", "sats", "resps", "GCS", "A and O", "PERRL", "BGL", "EtCO2", "12-lead",
    "STEMI", "compensating", "aspirin", "nitro sublingual", "Narcan", "Zofran", "fentanyl", "Versed",
    "ketamine", "epi", "albuterol", "DuoNeb", "D10", "glucagon", "amiodarone", "Solu-Medrol", "Benadryl", "normal saline",
    "IV", "IO", "IM", "intranasal", "gauge left AC", "non-rebreather", "nasal cannula", "CPAP", "BVM", "i-gel",
    "C-collar", "tourniquet", "ROSC", "afib", "sinus tach", "NKDA", "PMH", "CHF", "COPD", "LKW", "dispatched for",
]

CONTEXT_REQUIRED = sorted({
    "asa", "epi", "neb", "ms", "mag", "pit", "hep", "neo", "vaso", "levo", "dex", "roc", "vec", "ket", "fent", "lido",
    "amio", "dilt", "sux", "succs", "sucks", "sugar", "juice", "orange juice", "glucose", "calcium", "magnesium",
    "saline", "bolus", "fluid bolus", "o2", "high flow", "nasal cannula", "nc", "non rebreather", "nrb", "blow by",
    "cpap", "bvm", "charcoal", "nitrous", "b1", "special k", "insulin", "regular insulin", "lr", "ns", "ringers",
    "nitrogen", "night row", "more feen", "breathing treatment", "a trophy", "label all", "mark one", "breathing treatment", "advil",
    "tylenol", "motrin", "benadryl", "pepcid", "zyrtec", "neffy", "auvi-q", "dex rose", "hal doll", "sole you med roll",
    "valley um", "at a van", "card is em", "low presser", "leave a fed", "by carb", "bi carb", "kepra", "play vix",
})

# FORMAT-ONLY prompt: vocabulary and abbreviation style, no realistic values.
# Every number is physically impossible (diastolic > systolic, SpO2 > 100, HR 913…), never appears
# in any test/dev call (digits or words), and falls outside the extractor's plausibility ranges, so
# a value Whisper copies from the prompt can never become a field. Doses carry units, not amounts.
# Check copies with core/tools/prompt_copy_check.py.
INITIAL_PROMPT = ("EMS call. Patient A&O, GCS. BP 61/127, HR 913, resps 113, sats 113%, BGL 913, ETCO2 213. "
                  "Aspirin mg PO, nitro mg SL, Narcan mg IN, D10, glucagon, albuterol, DuoNeb, epi mg IM, "
                  "Benadryl, Solu-Medrol, Zofran mg IV, fentanyl mcg, Versed, Ativan, amiodarone, adenosine, TXA. "
                  "12-lead, STEMI, IV, IO, CPAP, BVM, c-collar.")

HTTP_HEADERS = {"User-Agent": "earshot-dictionary-builder/1.0"}


def fetch_json(url, cache):
    if url in cache:
        return cache[url]
    req = urllib.request.Request(url, headers=HTTP_HEADERS)
    data = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                data = json.loads(r.read().decode("utf-8"))
            break
        except urllib.error.HTTPError as e:
            if e.code == 404:
                data = {}
                break
            time.sleep(1 + attempt)
        except Exception:
            time.sleep(1 + attempt)
    if data and "api.fda.gov" in url:  # keep cache small: routes only
        data = {"results": [{"openfda": {"route": (r.get("openfda") or {}).get("route", [])}}
                            for r in data.get("results") or []]}
    cache[url] = data
    time.sleep(0.06)  # be polite: RxNav allows 20 req/s
    return data


def rxnorm(generic, cache):
    q = urllib.parse.quote(generic)
    d = fetch_json(f"https://rxnav.nlm.nih.gov/REST/rxcui.json?name={q}&search=2", cache) or {}
    ids = (d.get("idGroup") or {}).get("rxnormId") or []
    if not ids:
        d = fetch_json(f"https://rxnav.nlm.nih.gov/REST/approximateTerm.json?term={q}&maxEntries=1", cache) or {}
        cands = (d.get("approximateGroup") or {}).get("candidate") or []
        ids = [cands[0]["rxcui"]] if cands else []
    if not ids:
        return None, []
    rxcui = ids[0]
    rel = fetch_json(f"https://rxnav.nlm.nih.gov/REST/rxcui/{rxcui}/related.json?tty=BN", cache) or {}
    brands = []
    for g in (rel.get("relatedGroup") or {}).get("conceptGroup") or []:
        for c in g.get("conceptProperties") or []:
            if len(c["name"]) > 18 or "/" in c["name"]:
                continue
            # keep single-ingredient brands only (drops e.g. dental
            # anesthetic + epinephrine combos that would mis-map)
            ing = fetch_json(f"https://rxnav.nlm.nih.gov/REST/rxcui/{c['rxcui']}/related.json?tty=IN+MIN", cache) or {}
            ins = [p for gg in (ing.get("relatedGroup") or {}).get("conceptGroup") or []
                   for p in gg.get("conceptProperties") or []]
            if len(ins) == 1 and ins[0].get("tty") == "IN":
                brands.append(c["name"])
    return rxcui, sorted(set(brands))


def openfda_routes(generic, cache):
    q = urllib.parse.quote(f'openfda.generic_name:"{generic}"')
    d = fetch_json(f"https://api.fda.gov/drug/label.json?search={q}&limit=20", cache) or {}
    routes = set()
    for r in d.get("results") or []:
        for x in (r.get("openfda") or {}).get("route") or []:
            routes.add(x.upper())
    return sorted(routes)


def nemsis_codes(nemsis_dir):
    out = {"routes": {}, "units": {}}
    if not nemsis_dir:
        return out
    pat = r'value="(\d+)">\s*<xs:annotation>\s*<xs:documentation>([^<]+)'
    ct = open(os.path.join(nemsis_dir, "commonTypes_v3.xsd"), encoding="utf-8").read()
    m = re.search(r'<xs:simpleType name="CurrentMedicationAdministrationRoute">(.*?)</xs:simpleType>', ct, re.S)
    if m:
        out["routes"] = dict(re.findall(pat, m.group(1)))
    em = open(os.path.join(nemsis_dir, "eMedications_v3.xsd"), encoding="utf-8").read()
    m = re.search(r'<xs:simpleType name="MedicationDosageUnits">(.*?)</xs:simpleType>', em, re.S)
    if m:
        out["units"] = dict(re.findall(pat, m.group(1)))
    return out


SUBS = [("ph", "f"), ("f", "ph"), ("c", "k"), ("k", "c"), ("y", "i"), ("i", "y"), ("z", "s"), ("s", "z"), ("x", "ks"),
        ("ine", "een"), ("ol", "all"), ("one", "own"), ("am", "um"), ("qu", "kw"), ("th", "t")]


def phonetic_variants(name):
    """Spelling variants that keep the same phonetic key: candidate ASR
    misspellings of a drug name. Deterministic (sorted)."""
    base = name.lower()
    key = phonetic_key(base)
    seen = set()
    frontier = {base}
    for _ in range(2):
        nxt = set()
        for w in frontier:
            for a, b in SUBS:
                idx = w.find(a)
                while idx != -1:
                    v = w[:idx] + b + w[idx + len(a):]
                    if v not in seen and v != base and phonetic_key(v) == key:
                        seen.add(v)
                        nxt.add(v)
                    idx = w.find(a, idx + 1)
            # drop a doubled letter
            for i in range(len(w) - 1):
                if w[i] == w[i + 1]:
                    v = w[:i] + w[i + 1:]
                    if v not in seen and v != base and phonetic_key(v) == key:
                        seen.add(v)
                        nxt.add(v)
        frontier = nxt
    return sorted(seen)[:12]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="shared")
    ap.add_argument("--cache", default=os.path.join(os.path.dirname(__file__), ".dict_cache.json"))
    ap.add_argument("--nemsis-dir", default=None)
    ap.add_argument("--offline", action="store_true", help="use cache only")
    ap.add_argument("--additions", default=os.path.join(os.path.dirname(__file__), "formulary_additions.json"),
                    help="data agent's append-only additions (observed ASR variants, missing aliases, new drugs, home meds)")
    args = ap.parse_args()

    cache = {}
    if os.path.exists(args.cache):
        cache = json.load(open(args.cache))
    if args.offline:
        global fetch_json
        fetch_json = lambda url, c: c.get(url)  # noqa: E731

    codes = nemsis_codes(args.nemsis_dir)
    drugs = []
    for generic, s in SEED.items():
        rxcui, brands = rxnorm(generic, cache)
        fda_routes = openfda_routes(generic, cache)
        # keep brand list short and speakable: drop combo products / long names
        speak_brands = brands[:10]
        aliases = sorted(set([generic] + [x.lower() for x in s["slang"]] + [b.lower() for b in speak_brands]))
        variants = set()
        for a in [generic] + s["slang"][:3]:
            for w in a.split():
                if len(w) > 4:
                    variants.update(phonetic_variants(w))
        drugs.append({
            "generic": generic,
            "class": s["cls"],
            "rxcui": rxcui,
            "brands": speak_brands,
            "slang": s["slang"],
            "aliases": aliases,
            "asr_variants": sorted(set(s["asr"]) | variants),
            "phonetic": sorted({phonetic_key(a) for a in [generic] + s["slang"] + speak_brands if a and " " not in a}),
            "typical_doses": [{"amount": d[0], "unit": d[1], "route": d[2]} for d in s["doses"]],
            "routes": s["routes"],
            "label_routes_openfda": fda_routes,
            "high_alert": bool(s.get("high_alert", False)),
        })

    home_meds = []
    if args.additions and os.path.exists(args.additions):
        add = json.load(open(args.additions))
        by = {d["generic"]: d for d in drugs}
        common = {"now", "no", "know", "sugars", "sugar", "pain", "fine", "and", "the", "a", "on", "in", "it", "is", "go", "give",
                  "got", "here", "there", "ok", "okay", "so", "say", "see", "seen", "fan", "fen", "mass", "officer", "doctor", "nurse", "patient"}
        for g, vs in (add.get("asr_variants_observed") or {}).items():
            if g in by:
                for v in vs:
                    w = v["variant"].lower().strip()
                    # never add everyday words or tiny tokens as drug spellings
                    if w in common or len(w) < 5 or (v.get("count", 1) < 2 and " " not in w and len(w) < 7):
                        continue
                    by[g]["asr_variants"] = sorted(set(by[g]["asr_variants"]) | {w})
        for g, al in (add.get("aliases_missing") or {}).items():
            if g in by:
                by[g]["aliases"] = sorted(set(by[g]["aliases"]) | {a.lower() for a in al if a.lower() not in common})
        for nd in add.get("new_drugs") or []:
            if nd["generic"] in by:
                continue
            drugs.append({
                "generic": nd["generic"], "class": nd.get("class", ""), "rxcui": rxnorm(nd["generic"], cache)[0],
                "brands": nd.get("brands", []), "slang": [], "aliases": sorted({nd["generic"]} | {a.lower() for a in nd.get("aliases", [])}),
                "asr_variants": nd.get("asr_variants", []),
                "phonetic": sorted({phonetic_key(a) for a in [nd["generic"]] + nd.get("brands", []) if " " not in a}),
                "typical_doses": [{"amount": t["amount"], "unit": t["unit"], "route": t.get("route", (nd.get("routes") or ["PO"])[0])} for t in nd.get("typical_doses", [])],
                "routes": nd.get("routes", []), "label_routes_openfda": [], "high_alert": False,
                "source": nd.get("source", "data agent"),
            })
        known = {d["generic"] for d in drugs}
        home_meds = sorted({h.lower() for h in add.get("home_meds_missing") or []} - known)

    routes = {k: {"spoken": v[0], "nemsis_code": v[1], "nemsis_label": codes["routes"].get(v[1])} for k, v in ROUTES.items()}
    units = {k: {"spoken": v[0], "nemsis_code": v[1], "nemsis_label": codes["units"].get(v[1])} for k, v in UNITS.items()}

    formulary = {
        # Aliases that are also everyday English (or too short to trust).
        # Extraction only accepts these when a dose, unit, route or an
        # administration verb is within a few words.
        "context_required_aliases": CONTEXT_REQUIRED,
        "version": "1.0.0",
        "generated_by": "core/tools/build_dictionary.py",
        "notes": "Typical doses are reference values from state protocols for plausibility checks ONLY. "
                 "Earshot never fills a dose it did not hear.",
        "drugs": drugs,
        # Patient's own (home) medications that EMS does not give. Matched only
        # in home-med context ("takes", "on", "prescribed") -> status kind home_med.
        "home_meds": home_meds,
        "routes": routes,
        "units": units,
        "nemsis": {"routes": codes["routes"], "units": codes["units"]},
    }
    seen = set()
    terms = []
    for t, exp, cat in TERMS:
        if t in seen:
            continue
        seen.add(t)
        terms.append({"term": t, "expansion": exp, "category": cat})
    ems_terms = {
        "version": "1.0.0",
        "generated_by": "core/tools/build_dictionary.py",
        "terms": terms,
        "initial_prompt_core": PROMPT_CORE,
        # Format-only sentence-style prompt (see INITIAL_PROMPT). Sentence style came from the data agent's
        # seed prompt (drug-name WER 26.9% vs 38.5% for a bare comma list); "sats"/"resps" keep the spoken
        # words (review R4-1). Its realistic values were replaced to rule out priming; re-measure WER.
        "initial_prompt": INITIAL_PROMPT,
    }
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "formulary.json"), "w") as f:
        json.dump(formulary, f, indent=1, sort_keys=False)
        f.write("\n")
    with open(os.path.join(args.out, "ems_terms.json"), "w") as f:
        json.dump(ems_terms, f, indent=1)
        f.write("\n")
    if not args.offline:
        with open(args.cache, "w") as f:
            json.dump(cache, f, sort_keys=True)
    print(f"drugs={len(drugs)} terms={len(terms)} routes={len(routes)} units={len(units)}")
    missing = [d["generic"] for d in drugs if not d["rxcui"]]
    print("no rxcui:", missing)


if __name__ == "__main__":
    main()
