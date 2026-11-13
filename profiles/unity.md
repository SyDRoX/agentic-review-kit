This is a Unity project in C#. Check these on every changed script:

- Per-frame cost: no allocation in `Update`, `LateUpdate`, `FixedUpdate` or anything they call every frame. Look for `new` on reference types,
  LINQ, string concatenation or interpolation, boxing, closures that capture, `GetComponent`, `Find*`, `Camera.main` in old Unity versions,
  and `foreach` over a non-array collection of structs.
- `UnityEngine.Object` null checks: `?.`, `??` and `is null` skip Unity's lifetime check, so a destroyed object passes them. `== null` and
  the implicit bool are the correct checks.
- Lifecycle order: `Awake` and `OnEnable` run before another object's `Start`. A field set in one object's `Start` is not ready in another
  object's `Awake`. `OnDisable` and `OnDestroy` also run on scene unload and on quit, when other objects may be gone already.
- Event and delegate subscriptions: every `+=` in `OnEnable` or `Awake` needs its `-=` in `OnDisable` or `OnDestroy`. A static event keeps a
  destroyed object alive and calls into it.
- Coroutines and async: a coroutine stops when its object is disabled or destroyed; `async` code does not, so after every `await` the object
  may be destroyed. `async void` loses exceptions.
- Serialization: renaming a `[SerializeField]` field or a serialized public field drops the saved value in every prefab and scene unless
  `[FormerlySerializedAs]` is added. Changing a serialized type does the same.
- Physics and time: physics work belongs in `FixedUpdate`; `Time.deltaTime` in `FixedUpdate` is the fixed step. Frame-rate dependent movement
  without `deltaTime` is a defect.
- Assembly boundaries: a new reference in an `.asmdef` must not point from runtime code to an Editor assembly, and Editor-only API
  (`UnityEditor`) in runtime code breaks the player build unless it is inside `#if UNITY_EDITOR`.
- Platform: code that runs on mobile must not rely on `System.IO` paths outside `Application.persistentDataPath`, on threads touching the
  Unity API, or on reflection that IL2CPP strips.

`.meta`, `.prefab`, `.unity` and `.asset` files are not reviewed line by line. Do report a script change that needs a prefab or scene change
the diff does not contain.
