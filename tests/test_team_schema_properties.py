"""Property-based tests for teams/schema/team.schema.json.

Rather than hand-picking example team.yaml documents (as validate_team_configs.py
does against the real files), Hypothesis generates many candidate values per
field - including adversarial ones clustered around each regex's boundaries
(empty strings, off-by-one lengths, stray characters) - and checks the schema's
verdict against a plain-Python reference implementation of the same rule.

A mismatch here means the schema's regex and the rule it's supposed to encode
have drifted apart - the kind of boundary bug hand-written examples tend to
miss (e.g. a schema regex that accidentally allows a 2-char team name, or
rejects a valid 32-char one).
"""

import json
import os
import re

import jsonschema
import pytest
from hypothesis import example, given, settings, strategies as st

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_PATH = os.path.join(REPO_ROOT, "teams", "schema", "team.schema.json")

with open(SCHEMA_PATH) as f:
    SCHEMA = json.load(f)

VALID_TEAM = "acme-payments"
VALID_OWNER = "acme-payments@company.com"
VALID_COST_CENTER = "CC-1234"
VALID_BUCKET = {"name": "uploads", "visibility": "private"}


def base_doc(**overrides):
    doc = {
        "team": VALID_TEAM,
        "owner": VALID_OWNER,
        "cost_center": VALID_COST_CENTER,
        "buckets": [VALID_BUCKET],
    }
    doc.update(overrides)
    return doc


def schema_accepts(doc):
    try:
        jsonschema.validate(instance=doc, schema=SCHEMA)
        return True
    except jsonschema.ValidationError:
        return False


# --- reference oracles, independent of the schema's own regex source -------

TEAM_RE = re.compile(r"^[a-z][a-z0-9-]{1,30}[a-z0-9]$")
OWNER_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
COST_CENTER_RE = re.compile(r"^CC-[0-9]{3,6}$")
BUCKET_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}[a-z0-9]$")


# Pure-random noise from this alphabet almost never lands exactly on a valid
# pattern (e.g. a 32-char team name starting with a letter and ending
# alphanumeric is a needle in a haystack), so most random draws only ever
# exercise the "obviously rejected" path. `shaped_strings` fixes that: with
# even odds it either emits raw noise (for the reject path) or builds a
# string with valid start/end characters at a length drawn from *around*
# each rule's boundary (off-by-one lengths included) - the region where a
# hand-tightened schema regex is actually likely to drift from the rule it's
# meant to encode.
_charset = st.sampled_from(list("abc012-_. @!"))
_body_charset = st.sampled_from(list("abc012-"))


def shaped_strings(lengths):
    boundary_lengths = st.sampled_from(sorted({n for l in lengths for n in (l - 1, l, l + 1) if n >= 0}))

    @st.composite
    def _shaped(draw):
        n = draw(boundary_lengths)
        if n == 0:
            return ""
        start = draw(st.sampled_from(list("abc0!@-")))
        end = draw(st.sampled_from(list("abc0!@-")))
        middle = draw(st.text(alphabet=_body_charset, min_size=max(0, n - 2), max_size=max(0, n - 2)))
        return (start + middle + end)[:n] if n >= 2 else start

    return st.one_of(st.text(alphabet=_charset, min_size=0, max_size=45), _shaped())


@given(candidate=shaped_strings(lengths=[3, 32]))
@settings(max_examples=300)
@example("a" * 32)  # exactly the max valid length
@example("a" * 33)  # one over the max
@example("aa")  # one under the min
@example("aaa")  # exactly the min valid length
def test_team_name_schema_matches_reference(candidate):
    doc = base_doc(team=candidate)
    assert schema_accepts(doc) == bool(TEAM_RE.match(candidate))


@given(candidate=shaped_strings(lengths=[5, 15]))
@settings(max_examples=200)
@example("a@b.com")
@example("a@b")
@example("@b.com")
def test_owner_schema_matches_reference(candidate):
    doc = base_doc(owner=candidate)
    assert schema_accepts(doc) == bool(OWNER_RE.match(candidate))


@given(candidate=shaped_strings(lengths=[6, 9]))
@settings(max_examples=200)
@example("CC-123")  # exactly the min valid length
@example("CC-123456")  # exactly the max valid length
@example("CC-12")  # one under the min
@example("CC-1234567")  # one over the max
def test_cost_center_schema_matches_reference(candidate):
    doc = base_doc(cost_center=candidate)
    assert schema_accepts(doc) == bool(COST_CENTER_RE.match(candidate))


@given(candidate=shaped_strings(lengths=[2, 42]))
@settings(max_examples=300)
@example("a" * 42)  # exactly the max valid length
@example("a" * 43)  # one over the max
@example("a")  # one under the min
@example("aa")  # exactly the min valid length
def test_bucket_name_schema_matches_reference(candidate):
    doc = base_doc(buckets=[{"name": candidate, "visibility": "private"}])
    assert schema_accepts(doc) == bool(BUCKET_NAME_RE.match(candidate))


# --- structural properties, not just per-field regexes ----------------------

@given(n=st.integers(min_value=1, max_value=20))
@settings(max_examples=30)
def test_any_nonempty_bucket_list_of_valid_buckets_is_accepted(n):
    doc = base_doc(buckets=[{"name": f"bucket{i}", "visibility": "private"} for i in range(n)])
    assert schema_accepts(doc)


def test_empty_bucket_list_is_always_rejected():
    assert not schema_accepts(base_doc(buckets=[]))


@given(visibility=st.text(min_size=0, max_size=10))
@settings(max_examples=50)
def test_visibility_only_accepts_exactly_public_or_private(visibility):
    doc = base_doc(buckets=[{"name": "uploads", "visibility": visibility}])
    assert schema_accepts(doc) == (visibility in ("public", "private"))


@given(extra_key=st.text(alphabet=st.sampled_from(list("abcxyz")), min_size=1, max_size=10))
@settings(max_examples=30)
def test_unknown_top_level_keys_are_always_rejected(extra_key):
    if extra_key in ("team", "owner", "cost_center", "buckets"):
        return
    doc = base_doc(**{extra_key: "anything"})
    assert not schema_accepts(doc)


@pytest.mark.parametrize("missing", ["team", "owner", "cost_center", "buckets"])
def test_each_required_field_is_actually_required(missing):
    doc = base_doc()
    del doc[missing]
    assert not schema_accepts(doc)
