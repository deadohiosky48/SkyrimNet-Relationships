Int Function LabelToOffset(String asLabel) Global
    { Maps a human activity name (as written in snrom_author_disposition.prompt)
      to its ROM_ faction's plugin-local FormID. Generated from CS_Romantasy.esp
      so it cannot drift from the actual records.
      Returns 0 for anything unrecognized - that IS the whitelist: a model that
      invents or misspells an activity gets rejected rather than interpreted. }
    String l = SNRom_Decorators.Upper(asLabel)
    If l == "ANIMALS KILLED"
        Return 0x821
    ElseIf l == "ARMOR MADE"
        Return 0x831
    ElseIf l == "ASSAULTS"
        Return 0x837
    ElseIf l == "AUTOMATONS KILLED"
        Return 0x825
    ElseIf l == "BACKSTABS"
        Return 0x828
    ElseIf l == "BARTERS"
        Return 0x808
    ElseIf l == "BRIBES"
        Return 0x80A
    ElseIf l == "BUNNIES SLAUGHTERED"
        Return 0x82A
    ElseIf l == "CHESTS LOOTED"
        Return 0x805
    ElseIf l == "CIVIL WAR COMPLETED"
        Return 0x81B
    ElseIf l == "COLLEGE COMPLETED"
        Return 0x818
    ElseIf l == "COMPANIONS COMPLETED"
        Return 0x817
    ElseIf l == "CREATURES KILLED"
        Return 0x822
    ElseIf l == "CRITICAL STRIKES"
        Return 0x826
    ElseIf l == "DAEDRA KILLED"
        Return 0x824
    ElseIf l == "DAEDRIC COMPLETED"
        Return 0x81C
    ElseIf l == "DARK BROTHERHOOD COMPLETED"
        Return 0x81A
    ElseIf l == "DAWNGUARD COMPLETED"
        Return 0x81D
    ElseIf l == "DAYS PASSED"
        Return 0x803
    ElseIf l == "DAYS VAMPIRE"
        Return 0x80D
    ElseIf l == "DAYS WEREWOLF"
        Return 0x80E
    ElseIf l == "DISEASES CONTRACTED"
        Return 0x80C
    ElseIf l == "DRAGON SOULS COLLECTED"
        Return 0x82C
    ElseIf l == "DRAGONBORN COMPLETED"
        Return 0x81E
    ElseIf l == "DUNGEONS CLEARED"
        Return 0x802
    ElseIf l == "HORSES STOLEN"
        Return 0x839
    ElseIf l == "INTIMIDATIONS"
        Return 0x80B
    ElseIf l == "ITEMS STOLEN"
        Return 0x836
    ElseIf l == "LOCATIONS DISCOVERED"
        Return 0x801
    ElseIf l == "LOCKS PICKED"
        Return 0x834
    ElseIf l == "MAGIC ITEMS MADE"
        Return 0x82F
    ElseIf l == "MAIN QUESTS COMPLETED"
        Return 0x815
    ElseIf l == "MAULS"
        Return 0x812
    ElseIf l == "MISC OBJECTIVES COMPLETED"
        Return 0x814
    ElseIf l == "MURDERS"
        Return 0x838
    ElseIf l == "NECKS BITTEN"
        Return 0x80F
    ElseIf l == "PEOPLE KILLED"
        Return 0x820
    ElseIf l == "PERSUASIONS"
        Return 0x809
    ElseIf l == "POCKETS PICKED"
        Return 0x835
    ElseIf l == "POISONS MIXED"
        Return 0x833
    ElseIf l == "POTIONS MIXED"
        Return 0x832
    ElseIf l == "QUESTLINES COMPLETED"
        Return 0x81F
    ElseIf l == "QUESTS COMPLETED"
        Return 0x813
    ElseIf l == "SHOUTS LEARNED"
        Return 0x82D
    ElseIf l == "SIDE QUESTS COMPLETED"
        Return 0x816
    ElseIf l == "SKILL BOOKS READ"
        Return 0x807
    ElseIf l == "SKILL INCREASES"
        Return 0x806
    ElseIf l == "SNEAK ATTACKS"
        Return 0x827
    ElseIf l == "SOULS TRAPPED"
        Return 0x82E
    ElseIf l == "SPELLS LEARNED"
        Return 0x82B
    ElseIf l == "STANDING STONES FOUND"
        Return 0x804
    ElseIf l == "THIEVES COMPLETED"
        Return 0x819
    ElseIf l == "TRESPASSES"
        Return 0x83A
    ElseIf l == "UNDEAD KILLED"
        Return 0x823
    ElseIf l == "VAMPIRISM CURES"
        Return 0x810
    ElseIf l == "WEAPONS DISARMED"
        Return 0x829
    ElseIf l == "WEAPONS MADE"
        Return 0x830
    ElseIf l == "WEREWOLF TRANSFORMATIONS"
        Return 0x811
    EndIf
    Return 0
EndFunction
