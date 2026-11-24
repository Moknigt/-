NEXORA EDU - Android + iPhone + Windows

Upload these to the root of a GitHub repo as they are (do NOT unzip android.zip, ios.zip or windows.zip):
  .github/  android.zip  ios.zip  windows.zip
Then: Actions -> "Build Android, iOS and Windows" -> download the APK, IPA and EXE from Artifacts.
The IPA is unsigned: install it with Sideloadly / AltStore / TrollStore or sign it with your own certificate.
The Windows EXE is unsigned: Windows SmartScreen may warn on first run (More info -> Run anyway).

Release 46 adds the interface sound effects to iPhone and Windows (Android has them since release 45; same sounds, see CHANGELOG). Release 40 adds server step 3 part 2 (the four R2 Edge Functions: upload-url, upload-complete, play-url, purge-deleted; not deployed yet, see HANDOFF.md). Release 39 adds server step 3 part 1 (R2 storages SQL with the hard 8 GiB limit, see HANDOFF.md; not run yet). Release 38 adds server step 2 (Paymob payment, see HANDOFF.md). Release 37 adds server step 1 (Supabase accounts and lock, see HANDOFF.md). Release 36 adds the server contract (SERVER_SPEC.md) and skeleton files only (Remote, PaymentFlow). Release 35 adds paid content on all three apps: video from a YouTube link or an uploaded file, free / paid price per video and per course, a lock for paid content, and manual opening (cash / free) by the teacher with a permanent log. The server check and electronic payment are skeletons (see CHANGELOG release 35). Release 26 brings iPhone teacher student controls and announcement editing closer to Android behavior. Release 25 aligned the Windows and iPhone glass surfaces with the Android 1.8.0 visual reference (same light/dark palette, rounded cards, translucent gradients and accent colors). Android remains unchanged. Release 24 extended the native Windows teacher/student workflows toward Android parity: announcements, student management and detail views, teacher class management, lesson editing/reordering/publishing, and student profile editing. See windows.zip/README.md for scope and remaining work.

iPhone version: native SwiftUI app with a real Xcode project (no WebView, no XcodeGen). See ios.zip/README.md.

Windows version: native WPF (C# + XAML, .NET 8), no Electron. Exams and homework (teacher + student) are in Windows since release 13 and in Android + iPhone since release 14. Rebuilt from scratch in parts; part 1 = student skeleton
(shell, Home, Courses, Exams, Profile) + splash, student sign-in and sign-up, hidden admin sign-in and the admin side (dashboard, teacher, students, content, my account). See windows.zip/README.md.
The Windows build reads android.zip to check that strings and colors match, so keep both in the repo.

Student profile photo: all three apps (Profile tab -> add / change / remove; shown in the header / sidebar).

Themes: all three apps (Android since release 16: Settings screen -> App colour row that opens a colour picker (release 17), Nexora + 11 accent themes; Windows and iPhone keep their own themes screen).

Admin side: Android and iPhone have a hidden admin side. On the sign-in screen, hold the flask logo for 7 seconds. See android.zip/README.md and ios.zip/README.md.

Package version: see the VERSION file. Name every new package NexoraEdu-All-v<release>.zip and raise `release` (and the Windows version in windows/NexoraEdu.csproj) each time.
If you continue the work: edit the existing files, do NOT rebuild from scratch, and keep android.zip / ios.zip / windows.zip as fixed names. Full rules: windows.zip/README.md -> "READ FIRST".
