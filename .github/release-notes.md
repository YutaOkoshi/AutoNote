> [!NOTE]
> この .app は Apple Developer ID で署名・公証していない（自己署名の証明書「AutoNote Dev」で署名）。初回は Finder で右クリック → 「開く」を選ぶか、展開したあとに次を実行してから開く。
>
> ```sh
> xattr -d com.apple.quarantine AutoNote.app
> ```
>
> 自動アップデートに対応した版からは、アプリが 1 日に 1 回新しい版を確かめて自分で入れ替える。すべての版を同じ証明書で署名するので、入れ替えてもマイク・システム音声録音の許可は保たれる。アドホック署名だった古い版（0.6.0 まで）からこの署名の版へ入れ替えるときだけ、許可をもう一度求められる。
> `AutoNote-<version>-macos-universal.zip` は Apple シリコンと Intel Mac の両方で動くユニバーサル版。
