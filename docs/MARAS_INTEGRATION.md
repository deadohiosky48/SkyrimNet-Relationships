# MARAS and Relationships

From 2.5 Relationships runs marriage itself: proposals, engagements, rings,
weddings and divorce. [MARAS](https://github.com/tetherball88/maras) is no longer
needed, and nothing in Relationships is taken from it. What remains is the way
out: MARAS's marriages are brought over once, and then MARAS is set aside.

How to do it is in the README, under *Moving from MARAS*. This page says what
happens underneath.

## Who runs marriage

**MARAS, only while it is installed and its marriages have not been brought
over.** In that window Relationships' own marriage features stand aside: its
proposal, marriage and wedding actions are not offered, and the dashboard
invites you to bring the marriages over. Nothing is ever written to MARAS.

**Relationships, from the first load after the import, whether or not MARAS is
still installed.** From then on only Relationships' own record speaks: who is
married, engaged or divorced, and how many spouses you have, are read from it,
never from MARAS. If MARAS is still installed:

- its SkyrimNet actions (proposals, engagements, divorces) are taken out of the
  action library for the session, so they are never offered;
- its proposals are closed on everyone Relationships knows;
- an engagement it makes anyway is reversed.

Removing MARAS afterwards is still the clean finish.

## What the import reads

Through `MARAS.psc`, once per person, guarded by
`Game.IsPluginInstalled("TT_MARAS.esp")`: who MARAS records as **married**,
**engaged**, **divorced** and **jilted**. Each becomes the same state in
Relationships' record, marked as brought over from MARAS. Anyone Relationships
already records is left as they are, so running the import again brings over
only what MARAS has recorded since. Nothing else of MARAS's is read.

Every marriage brought over stands, however many there are. Marrying again while
married is Relationships' own setting, **Marry More Than One Spouse**.

## The MARAS Stub

Saves made while MARAS was installed list its plugins, `TT_MARAS.esp` and
`TT_Maras_OStim.esp`, and may refuse to load without them. The **MARAS Stub**
download holds two plugins with those names: a file header each, no records, no
scripts. Enable them in place of MARAS and its OStim patch, never beside them,
for as long as you play saves that needed them.
