package com.kuhy.focusstatus;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

/**
 * Tiny invisible activity so the app is launchable from the Minimalist
 * Phone app list. Starts the foreground service and finishes immediately.
 */
public final class LaunchActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        startForegroundService(new Intent(this, StatusService.class));
        finish();
    }
}
