String Function OffsetToStatName(Int aiOffset) Global
    { Maps a ROM_ preference faction's plugin-local FormID to the statistic NAME
      Romantasy.SetPreference expects. GENERATED from CS_Romantasy.esp, from each
      FACT record's FULL field, so it cannot drift from the records themselves.

      THIS IS NOT _labelmap.inc REVERSED, and that is the whole reason it exists.
      Ten of our prompt-facing labels are shorthands that are NOT the statistic
      name: CIVIL WAR COMPLETED is really "Civil War Quests Completed", COMPANIONS
      COMPLETED is "The Companions Quests Completed". That never mattered while a
      FormID was the identity and the label only had to be unique among labels.
      SetPreference matches on the NAME, so reusing the label would fail for
      exactly those ten and no others - ten silent rejections out of fifty-eight,
      which would read like a model fault for weeks.

      Returns "" for anything unmapped; callers must treat that as do-not-write. }
    If aiOffset == 0x801
        Return "Locations Discovered"
    ElseIf aiOffset == 0x802
        Return "Dungeons Cleared"
    ElseIf aiOffset == 0x803
        Return "Days Passed"
    ElseIf aiOffset == 0x804
        Return "Standing Stones Found"
    ElseIf aiOffset == 0x805
        Return "Chests Looted"
    ElseIf aiOffset == 0x806
        Return "Skill Increases"
    ElseIf aiOffset == 0x807
        Return "Skill Books Read"
    ElseIf aiOffset == 0x808
        Return "Barters"
    ElseIf aiOffset == 0x809
        Return "Persuasions"
    ElseIf aiOffset == 0x80A
        Return "Bribes"
    ElseIf aiOffset == 0x80B
        Return "Intimidations"
    ElseIf aiOffset == 0x80C
        Return "Diseases Contracted"
    ElseIf aiOffset == 0x80D
        Return "Days as a Vampire"
    ElseIf aiOffset == 0x80E
        Return "Days as a Werewolf"
    ElseIf aiOffset == 0x80F
        Return "Necks Bitten"
    ElseIf aiOffset == 0x810
        Return "Vampirism Cures"
    ElseIf aiOffset == 0x811
        Return "Werewolf Transformations"
    ElseIf aiOffset == 0x812
        Return "Mauls"
    ElseIf aiOffset == 0x813
        Return "Quests Completed"
    ElseIf aiOffset == 0x814
        Return "Misc Objectives Completed"
    ElseIf aiOffset == 0x815
        Return "Main Quests Completed"
    ElseIf aiOffset == 0x816
        Return "Side Quests Completed"
    ElseIf aiOffset == 0x817
        Return "The Companions Quests Completed"
    ElseIf aiOffset == 0x818
        Return "College of Winterhold Quests Completed"
    ElseIf aiOffset == 0x819
        Return "Thieves' Guild Quests Completed"
    ElseIf aiOffset == 0x81A
        Return "The Dark Brotherhood Quests Completed"
    ElseIf aiOffset == 0x81B
        Return "Civil War Quests Completed"
    ElseIf aiOffset == 0x81C
        Return "Daedric Quests Completed"
    ElseIf aiOffset == 0x81D
        Return "Dawnguard Quests Completed"
    ElseIf aiOffset == 0x81E
        Return "Dragonborn Quests Completed"
    ElseIf aiOffset == 0x81F
        Return "Questlines Completed"
    ElseIf aiOffset == 0x820
        Return "People Killed"
    ElseIf aiOffset == 0x821
        Return "Animals Killed"
    ElseIf aiOffset == 0x822
        Return "Creatures Killed"
    ElseIf aiOffset == 0x823
        Return "Undead Killed"
    ElseIf aiOffset == 0x824
        Return "Daedra Killed"
    ElseIf aiOffset == 0x825
        Return "Automatons Killed"
    ElseIf aiOffset == 0x826
        Return "Critical Strikes"
    ElseIf aiOffset == 0x827
        Return "Sneak Attacks"
    ElseIf aiOffset == 0x828
        Return "Backstabs"
    ElseIf aiOffset == 0x829
        Return "Weapons Disarmed"
    ElseIf aiOffset == 0x82A
        Return "Bunnies Slaughtered"
    ElseIf aiOffset == 0x82B
        Return "Spells Learned"
    ElseIf aiOffset == 0x82C
        Return "Dragon Souls Collected"
    ElseIf aiOffset == 0x82D
        Return "Shouts Learned"
    ElseIf aiOffset == 0x82E
        Return "Souls Trapped"
    ElseIf aiOffset == 0x82F
        Return "Magic Items Made"
    ElseIf aiOffset == 0x830
        Return "Weapons Made"
    ElseIf aiOffset == 0x831
        Return "Armor Made"
    ElseIf aiOffset == 0x832
        Return "Potions Mixed"
    ElseIf aiOffset == 0x833
        Return "Poisons Mixed"
    ElseIf aiOffset == 0x834
        Return "Locks Picked"
    ElseIf aiOffset == 0x835
        Return "Pockets Picked"
    ElseIf aiOffset == 0x836
        Return "Items Stolen"
    ElseIf aiOffset == 0x837
        Return "Assaults"
    ElseIf aiOffset == 0x838
        Return "Murders"
    ElseIf aiOffset == 0x839
        Return "Horses Stolen"
    ElseIf aiOffset == 0x83A
        Return "Trespasses"
    EndIf
    Return ""
EndFunction
