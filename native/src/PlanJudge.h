#pragma once

#include <cstdint>
#include <string>

// THE PLANNER HEARD (the author, 2026-11-03: "Build the backstop"). A wedding
// plan is recorded when the planner chooses the Wedding action in the reply
// that agrees to it. On SkyrimNet 29.1 rc2 that reply chose no action most of
// the time, and on 29.2 rc1 (which repeats the actions at the prompt's end)
// still lost two of three: the guests, and a reply that settled two things at
// once, where only one ACTION line is allowed.
//
// So a conversation with the hired planner is also HEARD (SkyrimNet's dialogue
// events, as the ceremony hears them) and, once the planner has answered and
// the room has gone quiet, judged by a prompt of our own (snrom_plan_judge):
// what did this exchange settle? Its answer goes to Papyrus (ModEvent
// SNRom_PlanHeard, the betrothed as sender), which records each part through
// the same functions the actions call, as the planner - so who may change
// what, the logging and the notes are one path. Recording the same thing
// twice changes nothing, so an action that did fire and the judge agree.
//
// Only while a planner is hired and the wedding is still being planned, and
// never during a ceremony.

namespace SNRom::PlanJudge {

    // kDataLoaded: SkyrimNet's custom prompt call (API v8+).
    void Register();

    // Papyrus at each load (natives v37): the LLM variant to judge with,
    // the same one the ceremony judge uses. Nothing is judged before it.
    void SetVariant(std::string a_variant);

    // A line SkyrimNet heard (Ceremony's dialogue events). Main thread.
    void Heard(std::uint32_t a_speaker, std::uint32_t a_target, const std::string& a_line);

    // One field of a judgment sent to Papyrus, by key (DAY, TIME, PLACE, NEAR,
    // OFFICIANT, INVITE_THEIRS, INVITE_YOURS, INVITE, UNINVITE, ADDRESS,
    // READING, RINGS, KISS, THEIR_STYLE, THEIR_METAL, YOUR_STYLE, YOUR_METAL,
    // OUTFIT, MARK); empty when it said nothing of it. From a VM thread.
    std::string Field(std::int32_t a_token, const std::string& a_key);

    // Natives v38: the marks and a place "here" from this judgment are made
    // where the player stood when they last spoke in it (WeddingPlan::
    // UseSpot), until Forget. False when they did not speak in it.
    bool UseSpotOf(std::int32_t a_token);

    // Papyrus is done with it; marks are made where the player stands again.
    void Forget(std::int32_t a_token);
}
