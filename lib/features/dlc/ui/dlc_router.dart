import 'package:bb_mobile/features/dlc/presentation/dlc_cubit.dart';
import 'package:bb_mobile/features/dlc/ui/screens/dlc_home_screen.dart';
import 'package:bb_mobile/locator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

enum DlcRoute {
  dlcHome('/dlcs');

  final String path;
  const DlcRoute(this.path);
}

class DlcRouter {
  static final route = GoRoute(
    name: DlcRoute.dlcHome.name,
    path: DlcRoute.dlcHome.path,
    pageBuilder: (context, state) => NoTransitionPage(
      key: state.pageKey,
      child: BlocProvider(
        create: (_) => locator<DlcCubit>(),
        child: const DlcHomeScreen(),
      ),
    ),
  );
}
