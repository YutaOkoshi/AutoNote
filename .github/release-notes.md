> [!NOTE]
> この .app は Apple Developer ID で署名・公証していない（CI でのアドホック署名のみ）。初回は Finder で右クリック → 「開く」を選ぶか、展開したあとに次を実行してから開く。
>
> ```sh
> xattr -d com.apple.quarantine AutoNote.app
> ```
>
> アドホック署名はビルドごとに署名が変わるため、マイク・システム音声録音などの許可は更新のたびに求められることがある。
> `AutoNote-<version>-macos-arm64.zip` は Apple シリコン用、`AutoNote-<version>-macos-x86_64.zip` は Intel Mac 用。
