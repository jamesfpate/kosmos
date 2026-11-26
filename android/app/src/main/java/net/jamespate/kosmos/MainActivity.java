package net.jamespate.kosmos;

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(MediaPlugin.class); // local plugins must be registered before super.onCreate
        super.onCreate(savedInstanceState);
    }
}
